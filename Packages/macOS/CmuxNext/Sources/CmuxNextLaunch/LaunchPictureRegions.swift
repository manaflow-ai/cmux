public import AppKit
import CmuxNextCompatAppKit
import CmuxNextDesign

/// The launch picture over the live root, region by region (plans/cmux-next/chrome-parity/
/// p08-startup.md section 3A, P4). The one ``LaunchPictureView`` that was the window's first frame stays over the live
/// root while the root is built behind it, masked: each part covers one region of the window (the sidebar, one
/// visible pane) and leaves at that region's own first meaningful content; the rest of the window (the title row,
/// the gutters, the screen bar) leaves with the last part, once no part comes later (``seal()``). The bound
/// (``LaunchPicturePhase/bound``) takes every part down (``leaveAll()``).
///
/// Chrome's Android startup keeps its first tab's capture until that tab's first meaningful paint, then fades it out
/// (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreview.java). A cmux window has many
/// regions under one capture, so the capture is masked per region and each region's part fades on its own.
///
/// The mask holds one opaque layer per part over its area and one even-odd layer for the rest of the picture; a part
/// leaves when its layer fades to clear through the `Motion.panes` gate (`.fadeOut`; one frame with animations off).
/// The areas are read again at each ``layout()`` (the root's layout calls it). Once the rest left, `finished` runs
/// (after the fade), and the phase takes the picture away.
///
/// ```swift
/// let regions = LaunchPictureRegions(picture: picture) { phase.remove() }
/// let sidebar = regions.add { picture in sidebarView.convert(sidebarView.bounds, to: picture) }
/// reveal.whenProduced(.sidebar) { regions.leave(sidebar) }
/// regions.seal()
/// ```
@MainActor
public final class LaunchPictureRegions {
    /// One region of the picture (``add(area:)``).
    public struct Part: Hashable, Sendable {
        let index: Int
    }

    @MainActor private final class Region {
        let area: @MainActor (NSView) -> CGRect
        let layer = CALayer()
        var isLeaving = false

        init(area: @escaping @MainActor (NSView) -> CGRect) {
            self.area = area
        }
    }

    private weak var picture: NSView?
    private let mask = CALayer()
    /// The picture outside every part's area.
    private let rest = CAShapeLayer()
    private var regions: [Region] = []
    private var isSealed = false
    /// The bound took the picture down (``leaveAll()``): no part left for its content.
    private var isExpired = false
    private var finished: (@MainActor () -> Void)?
    /// Runs as a part or the rest leaves (``LaunchPictureInput``'s held clicks): its name
    /// (``holder(at:)``) and whether its region drew its content (false at the bound).
    var partLeft: (@MainActor (_ holder: String, _ drawn: Bool) -> Void)?
    /// The whole picture left: every part and the rest.
    public private(set) var isFinished = false

    /// Masks `picture`, which shows whole until a part is added.
    ///
    /// - Parameters:
    ///   - picture: The launch picture over the live root.
    ///   - finished: Runs once the rest of the picture left and its fade ended: the picture may go.
    public init(picture: LaunchPictureView, finished: @escaping @MainActor () -> Void) {
        self.picture = picture
        self.finished = finished
        mask.actions = Self.still()
        rest.actions = Self.still()
        rest.fillRule = .evenOdd
        rest.fillColor = CGColor(gray: 0, alpha: 1)
        mask.addSublayer(rest)
        picture.layer?.mask = mask
        layout()
    }

    /// No implicit animation: an area and its mask move with the root in one frame.
    private static func still() -> [String: any CAAction] {
        ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "path": NSNull(), "sublayers": NSNull(), "opacity": NSNull()]
    }

    /// A part over `area`: the picture shows there until ``leave(_:)``.
    ///
    /// - Parameter area: The region's area in the picture's coordinates, asked again at each ``layout()`` (empty once
    ///   the region left the window).
    public func add(area: @escaping @MainActor (_ picture: NSView) -> CGRect) -> Part {
        let region = Region(area: area)
        region.layer.actions = Self.still()
        region.layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        mask.addSublayer(region.layer)
        regions.append(region)
        layout()
        return Part(index: regions.count - 1)
    }

    /// `part`'s region shows its first meaningful content: the part fades out. Later calls do nothing.
    public func leave(_ part: Part) {
        guard !isFinished, regions.indices.contains(part.index), !regions[part.index].isLeaving else { return }
        regions[part.index].isLeaving = true
        fade(regions[part.index].layer)
        partLeft?(Self.partName(part.index), true)
        finishIfLast()
    }

    /// No part comes later: the rest of the picture leaves with the last part (at once when every part left).
    public func seal() {
        isSealed = true
        finishIfLast()
    }

    /// The bound: every part and the rest fade out now, content or not.
    public func leaveAll() {
        isExpired = true
        for (index, region) in regions.enumerated() where !region.isLeaving {
            region.isLeaving = true
            fade(region.layer)
            partLeft?(Self.partName(index), false)
        }
        seal()
    }

    /// Keeps each part on its area and the rest of the picture outside them.
    ///
    /// - Returns: False once the whole picture left.
    @discardableResult
    public func layout() -> Bool {
        guard !isFinished, let picture else { return false }
        let bounds = picture.bounds
        mask.frame = bounds
        rest.frame = bounds
        let outside = CGMutablePath()
        outside.addRect(bounds)
        for region in regions {
            let area = region.area(picture).intersection(bounds)
            region.layer.frame = area.isNull ? .zero : area
            if !region.layer.frame.isEmpty { outside.addRect(region.layer.frame) }
        }
        rest.path = outside
        return true
    }

    /// Whether the picture still shows at `point`, in the picture's coordinates: a part that has not left covers its
    /// area, the rest covers what no part's area does.
    public func covers(_ point: CGPoint) -> Bool {
        guard !isFinished, let picture, picture.bounds.contains(point) else { return false }
        guard let region = regions.first(where: { $0.layer.frame.contains(point) }) else { return true }
        return !region.isLeaving
    }

    /// The name of the part that still shows the picture at `point` (``partLeft``), ``rest`` outside every part's
    /// area; nil where the picture no longer shows.
    func holder(at point: CGPoint) -> String? {
        guard covers(point) else { return nil }
        return regions.firstIndex { $0.layer.frame.contains(point) }.map(Self.partName) ?? Self.rest
    }

    nonisolated static let rest = "rest"

    private static func partName(_ index: Int) -> String { "part-\(index)" }

    /// `part`'s layer in the mask (tests read its fade).
    func layer(of part: Part) -> CALayer? {
        regions.indices.contains(part.index) ? regions[part.index].layer : nil
    }

    private func finishIfLast() {
        guard isSealed, !isFinished, regions.allSatisfy(\.isLeaving), let finished else { return }
        isFinished = true
        self.finished = nil
        partLeft?(Self.rest, !isExpired)
        // With animations off (or no screen to draw on) the rest goes in this frame, the picture with it.
        guard fades else {
            fade(rest)
            return finished()
        }
        CATransaction.begin()
        CATransaction.setMainCompletion { finished() }
        fade(rest)
        CATransaction.commit()
    }

    /// A part fades out only on a screen and while the panes' fades run; otherwise it goes in one frame.
    private var fades: Bool { picture?.window?.screen != nil && Motion.panes.duration(.fadeOut) > 0 }

    private func fade(_ layer: CALayer) {
        guard fades else {
            layer.opacity = 0 // no action: one frame
            return
        }
        Motion.panes.set(layer, "opacity", to: Float(0), fade: .fadeOut, from: Float(1))
    }
}
