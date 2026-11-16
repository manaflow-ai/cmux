// cmux: Find in a Home chat (Cmd-F). Not a vendored file.
import AppKit

/// Find in the Home transcript, as the agent chat's Find in Chat finds (webviews chatFind.ts): every
/// match of the query in the loaded rows' text, case-insensitive, oldest first, one of them current.
/// Each row's cell draws its matches in two layers under the selection highlight (`draw(_:)`, run as
/// the list configures a cell), so they ride the row's springs and scrolls, and a reused cell redraws.
final class TranscriptFind {
    struct Match: Equatable {
        let key: String
        let range: NSRange
    }

    private weak var controller: ChatController?
    private(set) var query = ""
    private(set) var matches: [Match] = []
    /// The index in `matches` of the current match; 0 when there are none.
    private(set) var current = 0
    /// Each row's matches (indexes into `matches`), so a cell draws without walking them all.
    private var byKey: [String: [Int]] = [:]

    init(controller: ChatController) { self.controller = controller }

    /// Searches for `query`; empty clears every highlight. The first match is current and shows.
    func search(_ query: String) {
        self.query = query
        current = 0
        collect()
        reveal()
        refresh()
    }

    /// The next (`forward`) or previous match, wrapping at the ends; the transcript scrolls to it.
    func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        current = (current + (forward ? 1 : -1) + matches.count) % matches.count
        reveal()
        refresh()
    }

    /// The rows changed (a message came, a reply grew): the matches follow, the current one kept while it is there.
    func rowsChanged() {
        guard !query.isEmpty else { return }
        let was = matches[checked: current]
        collect()
        if let was, let i = matches.firstIndex(of: was) { current = i } else { current = min(current, max(0, matches.count - 1)) }
        refresh()
    }

    /// The 1-based current match and the count (0 and 0: no match).
    var position: (current: Int, total: Int) { matches.isEmpty ? (0, 0) : (current + 1, matches.count) }

    /// `query`'s ranges in `text`, case-insensitive, not overlapping, in order.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: query, options: .caseInsensitive, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            out.append(r)
            from = NSMaxRange(r)
        }
        return out
    }

    private func collect() {
        matches = []
        byKey = [:]
        guard !query.isEmpty, let demo = controller?.demo else { return }
        for row in demo.model.rows where !row.ghost && row.spec.key.hasPrefix("part:") {
            guard let g = TranscriptSelection.geometry(row.spec) else { continue }
            for range in Self.ranges(of: query, in: g.substring(NSRange(location: 0, length: g.length))) {
                byKey[row.spec.key, default: []].append(matches.count)
                matches.append(Match(key: row.spec.key, range: range))
            }
        }
    }

    /// Scrolls the current match into view when it is not between the header and the field.
    private func reveal() {
        guard let demo = controller?.demo, let m = matches[checked: current], let i = demo.model.index.value(for: m.key),
              let spec = demo.model.rows[checked: i]?.spec, let g = TranscriptSelection.geometry(spec) else { return }
        let body = RowDraw.bodyRect(spec)
        let line = g.selectionRects(m.range, visible: -1e9...1e9).first.map { $0.offsetBy(dx: body.minX, dy: body.minY) }
            ?? body
        for case let cell as RowCell in demo.collection.visibleCells where cell.key == m.key && !cell.isHidden {
            let shown = cell.convert(line, to: demo)
            if shown.minY >= demo.visibleTop, shown.maxY <= demo.fieldTop - 8 { return }
        }
        demo.revealFindMatch(row: i, lineTop: line.minY)
    }

    /// Redraws the matches of the rows on screen.
    func refresh() {
        guard let demo = controller?.demo else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for case let cell as RowCell in demo.collection.visibleCells { draw(cell) }
        CATransaction.commit()
    }

    /// One cell's matches (MessagesWindowView.onCellDecorated runs it for each cell the list configures).
    func draw(_ cell: RowCell) {
        guard !cell.isHidden, let mine = byKey[cell.key], let demo = controller?.demo, let i = demo.model.index.value(for: cell.key),
              let spec = demo.model.rows[checked: i]?.spec, let g = TranscriptSelection.geometry(spec) else {
            cell.setFindHighlight(all: nil, current: nil)
            return
        }
        let body = RowDraw.bodyRect(spec)
        // A screen above to a screen below: a row that springs or slides in brings its highlight along.
        let h = demo.bounds.height
        let top = cell.convert(CGRect.zero, to: demo).minY
        let visible = (demo.bounds.minY - h - top)...(demo.bounds.maxY + h - top)
        let all = CGMutablePath(), now = CGMutablePath()
        for n in mine {
            guard let m = matches[checked: n] else { continue }
            for r in TranscriptSelection.highlightRects(m.range, body: body, geometry: g, visible: visible) {
                let rect = r.insetBy(dx: -1, dy: 0)
                let corner = min(2.5, rect.width / 2, rect.height / 2)
                (n == current ? now : all).addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
            }
        }
        cell.setFindHighlight(all: all.isEmpty ? nil : all, current: now.isEmpty ? nil : now)
    }
}

extension MessagesWindowView {
    /// Scrolls so row `i`'s line at `lineTop` (row-local) sits a third down the transcript, within the
    /// scroll range (a short row: its top under the header, as `revealHostMessage` places it).
    func revealFindMatch(row i: Int, lineTop: CGFloat) {
        let y = layout.contentTop(i) - (rowsTopInset - MessagesWindowView.cvTop) - 8 + max(0, lineTop - bounds.height / 3)
        setOffset(min(max(minOffset, y), pinnedOffset))
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        userScrolled()
    }
}

/// A cell's two find layers, made on its first match.
private final class FindLayers {
    let all = CAShapeLayer()
    let current = CAShapeLayer()
}

private let findLayersKey = AssociationKey()

extension RowCell {
    /// The cell's find highlights (cell coordinates): every match in yellow, the current one in orange,
    /// the agent chat's colours (webviews find/highlight.ts). Nil and nil: none.
    func setFindHighlight(all: CGPath?, current: CGPath?) {
        var layers = objc_getAssociatedObject(self, findLayersKey.pointer) as? FindLayers
        if all == nil, current == nil, layers == nil { return }
        if layers == nil {
            let made = FindLayers()
            for l in [made.all, made.current] {
                l.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                // Under the selection highlight (zPosition 100), over the row's bitmap and tiles.
                l.zPosition = 99
            }
            objc_setAssociatedObject(self, findLayersKey.pointer, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            layers = made
        }
        guard let layers else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let light = Fixture.lightAppearance
        layers.all.fillColor = NSColor(srgbRed: 1, green: 199 / 255, blue: 0, alpha: light ? 0.42 : 0.34).cgColor
        layers.current.fillColor = (light ? NSColor(srgbRed: 1, green: 0x96 / 255, blue: 0x32 / 255, alpha: 0.62)
                                          : NSColor(srgbRed: 0xe8 / 255, green: 0x82 / 255, blue: 0x1e / 255, alpha: 0.62)).cgColor
        for l in [layers.all, layers.current] where l.superlayer !== contentView.layer && (all != nil || current != nil) {
            contentView.layer.addSublayer(l)
        }
        layers.all.path = all
        layers.current.path = current
        CATransaction.commit()
    }

    /// The find highlight paths this cell draws now (tests).
    var findHighlightPaths: (all: CGPath?, current: CGPath?) {
        let layers = objc_getAssociatedObject(self, findLayersKey.pointer) as? FindLayers
        return (layers?.all.path, layers?.current.path)
    }
}
