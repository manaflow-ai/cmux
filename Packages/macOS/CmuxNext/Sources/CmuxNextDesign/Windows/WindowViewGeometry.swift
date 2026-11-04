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
    }

    public static let maxDepth = 16
    public static let maxViews = 6000
    private(set) var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    public init(window: NSWindow) {
        guard let content = window.contentView else { return }
        self.init(root: content.superview ?? content)
    }

    /// The tree under `root` (a window's frame view: the titlebar and the content).
    public init(root: NSView) {
        var stack: [(view: NSView, depth: Int, drawn: Bool)] = [(root, 0, true)]
        while let item = stack.popLast(), entries.count < Self.maxViews {
            let view = item.view
            let drawn = item.drawn && !view.isHidden && view.alphaValue > 0.01
            entries[ObjectIdentifier(view)] = Entry(name: String(describing: type(of: view)), rect: view.convert(view.bounds, to: nil).integral, drawn: drawn)
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
                if now.drawn { note("\(now.name) appeared \(Self.text(now.rect))") }
                continue
            }
            guard was.drawn || now.drawn else { continue }
            if was.drawn != now.drawn {
                note("\(now.name) \(now.drawn ? "shown" : "hidden") \(Self.text(now.rect))")
            } else if was.rect != now.rect {
                note("\(now.name) moved \(Self.text(was.rect)) -> \(Self.text(now.rect))")
            }
        }
        for (id, was) in previous.entries where was.drawn && entries[id] == nil {
            note("\(was.name) went away \(Self.text(was.rect))")
        }
        return (total, lines.sorted())
    }

    public static func text(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }
}
#endif
