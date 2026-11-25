#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// DEBUG ONLY. One frame's view geometry for a `--record-launch` recording (CmuxNextApp's `DebugWindowRecord`): every view of
/// the window from its frame view down (at most ``maxDepth`` levels and ``maxViews`` views), by identity, with its
/// frame in window coordinates and whether it is drawn (it and its superviews are not hidden and not clear).
/// ``changes(since:)`` names what moved between two frames, so a relaunch bench (scripts/cmux-next/launch_shift.py)
/// counts the frames after the first one in which anything on screen moved, resized, appeared or went away
/// (Leo, 2026-11-04: the relaunch after a nightly update "does too many layout shifts/flicker renderings").
/// Read on the main thread once a recorded frame; nothing else reads it.
public struct WindowViewGeometry {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let rect: CGRect
        public let drawn: Bool
        /// Drawn and with an area: on screen.
        public var isVisible: Bool { drawn && rect.width > 0 && rect.height > 0 }
    }

    public static let maxDepth = 16
    public static let maxViews = 6000
    private(set) var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    /// The window's views, and the layout planes its overlay panel holds above its pages.
    ///
    /// While a Chromium page shows, the window's overlay plane (pane rings and dims) moves into the
    /// click-through panel above the page windows (`WindowOverlayLayer`) and back when none shows. The
    /// plane draws at the same place in either window, so its views are read from both, in this
    /// window's coordinates: a plane that changed windows at its place did not move on screen. Only the
    /// panel's plane container counts; its own chrome and the overlays it presents are other windows.
    public init(window: NSWindow) {
        if let content = window.contentView {
            self.init(root: content.superview ?? content)
        } else {
            self.init()
        }
        for case let panel as OverlayHostPanel in window.childWindows ?? [] where panel.isVisible {
            for plane in panel.planeContainer.subviews {
                add(root: plane) { rect in window.convertFromScreen(panel.convertToScreen(rect)) }
            }
        }
    }

    /// The tree under `root` (a window's frame view: the titlebar and the content).
    public init(root: NSView) {
        add(root: root) { $0 }
    }

    /// Adds the tree under `root`, its window rects mapped by `place` (into the recorded window's coordinates).
    private mutating func add(root: NSView, place: (CGRect) -> CGRect) {
        var stack: [(view: NSView, depth: Int, drawn: Bool)] = [(root, 0, true)]
        while let item = stack.popLast(), entries.count < Self.maxViews {
            let view = item.view
            let drawn = item.drawn && !view.isHidden && view.alphaValue > 0.01
            let rect = place(view.convert(view.bounds, to: nil)).integral
            entries[ObjectIdentifier(view)] = Entry(name: String(describing: type(of: view)), rect: rect, drawn: drawn)
            // A view that is not drawn hides its subtree: its subviews' frames are not on screen.
            guard drawn, item.depth < Self.maxDepth else { continue }
            for subview in view.subviews { stack.append((subview, item.depth + 1, drawn)) }
        }
    }

    public var count: Int { entries.count }

    /// What changed on screen since `previous`, one line per view (`Name moved x,y,w,h -> x,y,w,h`,
    /// `Name shown`, `Name hidden`, `Name appeared`, `Name went away`), at most `limit` lines; `total` counts them all.
    /// A view that is not drawn in either frame does not count, whatever its frame did.
    public func changes(since previous: WindowViewGeometry, limit: Int = 6) -> (total: Int, lines: [String]) {
        var total = 0
        var lines: [String] = []
        func note(_ line: @autoclosure () -> String) {
            total += 1
            if lines.count < limit { lines.append(line()) }
        }
        for (id, now) in entries {
            guard let was = previous.entries[id] else {
                if now.isVisible { note("\(now.name) appeared \(Self.text(now.rect))") }
                continue
            }
            // A view with no area draws nothing: an empty status dot shown or hidden, or a toolbar laid out from zero size
            // (that one counts once it has an area).
            guard was.isVisible || now.isVisible else { continue }
            if was.isVisible != now.isVisible {
                note("\(now.name) \(now.isVisible ? "shown" : "hidden") \(Self.text(was.isVisible ? was.rect : now.rect))")
            } else if was.rect != now.rect {
                note("\(now.name) moved \(Self.text(was.rect)) -> \(Self.text(now.rect))")
            }
        }
        for (id, was) in previous.entries where was.isVisible && entries[id] == nil {
            note("\(was.name) went away \(Self.text(was.rect))")
        }
        return (total, lines.sorted())
    }

    public static func text(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }
}
#endif
