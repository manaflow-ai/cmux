public import AppKit

/// A view that reports frames for `debug.top_alignment` (the window top's shared lines, Leo
/// 2026-11-07: "align the top bit of the sidebar with the tabs/vice versa, and likewise the top of
/// the sidebar with the subsequent elements below"). Each frame is in the view's own coordinates;
/// the probe converts them.
@MainActor
public protocol TopAlignmentReporting: NSView {
    /// What the view is (`tabs`, `sidebar`): the probe keeps the topmost, then leftmost, of each kind.
    var topAlignmentKind: String { get }
    /// Named frames in this view's coordinates; a zero-width frame names an x line.
    func topAlignmentFrames() -> [String: CGRect]
}

/// `debug.top_alignment`: a window's top-row and sidebar-column frames in window points from the
/// top-left, rounded to 0.01, short enough for one tour step's output: the traffic lights, the
/// toolbar band's buttons (by accessibility identifier) and each ``TopAlignmentReporting`` kind.
@MainActor
public struct TopAlignmentProbe {
    public let window: NSWindow

    public init(window: NSWindow) { self.window = window }

    /// The toolbar band's buttons by their accessibility identifiers.
    static let bandButtons = ["toggle": "cmux.titlebar.toggleSidebar", "back": "cmux.titlebar.back", "forward": "cmux.titlebar.forward"]

    /// The report as a JSONSerialization graph.
    public func report() -> [String: Any] {
        guard let content = window.contentView else { return [:] }
        let height = content.bounds.height
        func topLeft(_ rect: CGRect, in view: NSView) -> CGRect {
            let inWindow = view.convert(rect, to: nil)
            return CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        }
        var out: [String: Any] = ["scale": Double(window.backingScaleFactor), "window": Self.box(window.frame)]
        if let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            out["lights"] = Self.box(CGRect(x: lights.minX, y: height - lights.maxY, width: lights.width, height: lights.height))
        }
        var best: [String: (anchor: CGRect, frames: [String: CGRect])] = [:]
        var pending: [NSView] = [content]
        while let view = pending.popLast() {
            guard !view.isHidden, view.alphaValue > 0 else { continue }
            if let id = view.accessibilityIdentifier() as String?, let key = Self.bandButtons.first(where: { $0.value == id })?.key,
               view.bounds.width > 0 {
                out[key] = Self.box(topLeft(view.bounds, in: view))
            }
            if let reporter = view as? any TopAlignmentReporting, reporter.bounds.width > 0 {
                let anchor = topLeft(reporter.bounds, in: reporter)
                if best[reporter.topAlignmentKind].map({ (anchor.minY, anchor.minX) < ($0.anchor.minY, $0.anchor.minX) }) ?? true {
                    best[reporter.topAlignmentKind] = (anchor, reporter.topAlignmentFrames().mapValues { topLeft($0, in: reporter) })
                }
            }
            pending.append(contentsOf: view.subviews)
        }
        for (kind, entry) in best {
            out[kind] = Self.box(entry.anchor)
            for (name, frame) in entry.frames { out[name] = frame.width == 0 ? Self.num(frame.minX) : Self.box(frame) }
        }
        return out
    }

    static func num(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }

    static func box(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map(num) }
}
