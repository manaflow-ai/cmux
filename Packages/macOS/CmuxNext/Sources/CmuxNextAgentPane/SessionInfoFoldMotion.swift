import AppKit
import CmuxNextDesign

/// A section fold of native Session Info as one state transition (Leo 2026-11-07, of a reference panel's
/// folds: "it needs to follow the little bumps and whatnot for the easing", "they dont overshoot but they
/// decelerate at the end"). Each folding section shows a share of its rows' height, 0 folded and 1 open; the
/// list lays its rows out at that share (the section's rows clip at its edge, every section below follows it,
/// and the panel's height is the list's), and the header's chevron turns with it. One progress on the settle
/// curve (`MotionCurve.settle`, `Motion.home`) drives every share, so all of it moves in the same frames.
struct SessionInfoFolds: Equatable {
    struct Leg: Equatable {
        var from: CGFloat
        var to: CGFloat
    }

    private(set) var legs: [String: Leg] = [:]
    private(set) var progress: CGFloat = 1

    var isFolding: Bool { !legs.isEmpty }

    /// The share of section `id`'s rows shown now, or nil when it is not folding (all or nothing).
    func share(_ id: String) -> CGFloat? {
        legs[id].map { $0.from + ($0.to - $0.from) * progress }
    }

    /// Starts folding section `id` toward `open`, from the share it shows now (an interrupted fold turns
    /// around where it is). Every other fold under way continues from its own share on the new run.
    mutating func fold(_ id: String, open: Bool) {
        var next: [String: Leg] = [:]
        for (key, leg) in legs { next[key] = Leg(from: share(key) ?? leg.to, to: leg.to) }
        next[id] = Leg(from: share(id) ?? (open ? 0 : 1), to: open ? 1 : 0)
        legs = next
        progress = 0
    }

    mutating func step(_ progress: Double) { self.progress = CGFloat(min(max(progress, 0), 1)) }

    /// Every fold is at its end.
    mutating func end() {
        legs = [:]
        progress = 1
    }
}

extension SessionInfoItem {
    /// The section header's id and whether it is unfolded, for a foldable section's header.
    var foldableHeader: (id: String, open: Bool)? {
        guard case .line(let line) = self, line.kind == .header, let id = line.id, let open = line.unfolded else { return nil }
        return (id, open)
    }

    /// Whether this is one of section `id`'s folding lines: a row or its "View all".
    func folds(in id: String) -> Bool {
        guard case .line(let line) = self, line.kind == .row || line.kind == .more, let lineID = line.id else { return false }
        return lineID.hasPrefix("row:\(id):") || lineID == "more:\(id)"
    }
}

extension Array where Element == SessionInfoItem {
    /// The sections whose fold differs between `self` (on screen) and `next` (the page's model): (id, opens).
    func foldChanges(to next: [SessionInfoItem]) -> [(id: String, open: Bool)] {
        let before = Dictionary(compactMap(\.foldableHeader).map { ($0.id, $0.open) }, uniquingKeysWith: { first, _ in first })
        return next.compactMap(\.foldableHeader).compactMap { header in
            guard let was = before[header.id], was != header.open else { return nil }
            return header
        }
    }

    /// Section `id`'s folding lines, those right under its header.
    func foldingLines(of id: String) -> [SessionInfoItem] {
        guard let header = firstIndex(where: { $0.foldableHeader?.id == id }) else { return [] }
        return Array(self[(header + 1)...].prefix { $0.folds(in: id) })
    }

    /// `self` with each closing section's leaving lines put back under its header, where they clip away.
    func keeping(_ leaving: [String: [SessionInfoItem]]) -> [SessionInfoItem] {
        guard !leaving.isEmpty else { return self }
        var result: [SessionInfoItem] = []
        for item in self {
            result.append(item)
            if let header = item.foldableHeader, !header.open, let lines = leaving[header.id] { result += lines }
        }
        return result
    }
}

/// A foldable header's chevron: one glyph that turns a quarter, pointing right folded and down open, so a
/// fold turns it on the fold's own progress instead of swapping two images.
final class SessionInfoChevronView: NSView {
    override var isFlipped: Bool { true }
    private let image: NSImage?
    /// 0 points right (folded), 1 points down (unfolded).
    var turn: CGFloat { didSet { if turn != oldValue { needsDisplay = true } } }

    init(font: NSFont, tint: NSColor, unfolded: Bool) {
        image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint])))
        turn = unfolded ? 1 : 0
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Degrees the glyph is drawn turned, clockwise on screen (this view is flipped): 0 right, 90 down.
    var degrees: CGFloat { 90 * turn }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(1, bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: degrees)
        transform.concat()
        image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
