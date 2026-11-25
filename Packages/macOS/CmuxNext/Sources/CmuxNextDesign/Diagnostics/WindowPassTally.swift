#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// `debug.frames`' window layout passes per window and per frame (DEV and bench builds): which window a pass laid out,
/// by its role (``LayoutPassRoleNaming``: "overlay panel", "divider catcher <id>"; a page window by its window number;
/// any other window by its class and window number), so a film that sees an extra pass in a borderless window
/// (`NSNextStepFrame`) names which one. Reads ``LayoutPassGuard/windowPassCounts`` once per frame, and walks the
/// windows only in a frame that had a pass; the passes themselves cost one counter add each.
@MainActor
public struct WindowPassTally {
    public struct Role {
        public var passes = 0
        /// Frames with at least one pass of this window, and with two or more.
        public var frames = 0
        public var framesTwoOrMore = 0
        public var max = 0
    }

    /// Each window's count at the last frame; a window at a reused address (another instance) starts from 0.
    private var marks: [ObjectIdentifier: (window: LayoutPassGuard.WeakWindow, passes: Int)] = [:]
    /// Totals since the last ``reset()``, by role.
    public private(set) var roles: [String: Role] = [:]
    /// Per frame (parallel to the probe's frames): the passes of each window that had one.
    public private(set) var perFrame: [[String: Int]] = []

    public init() {}

    /// Stops counting per window (`debug.frames` stop).
    public mutating func stop() {
        LayoutPassGuard.shared.countsPassesByWindow = false
        marks.removeAll()
    }

    /// Counts from now (counting per window starts with the first frame: only a running probe ticks).
    public mutating func reset() {
        marks.removeAll()
        for (window, passes) in LayoutPassGuard.shared.windowPassCounts { marks[ObjectIdentifier(window)] = (.init(object: window), passes) }
        roles.removeAll()
        perFrame.removeAll(keepingCapacity: true)
    }

    /// One frame: `windowPasses` is the frame's window pass count (`LayoutPassGuard.windowLayoutPasses` delta).
    public mutating func frame(windowPasses: Int, records: Bool = true) {
        if !LayoutPassGuard.shared.countsPassesByWindow { LayoutPassGuard.shared.countsPassesByWindow = true }
        // Slots for the windows there are now, before the next frame's passes (a window made since counts as no slot once).
        defer { LayoutPassGuard.shared.registerWindowsForPassCounts(NSApp?.windows ?? []) }
        guard windowPasses > 0 else { return records ? perFrame.append([:]) : () }
        var frame: [String: Int] = [:]
        for (window, passes) in LayoutPassGuard.shared.windowPassCounts {
            let id = ObjectIdentifier(window)
            let mark = marks[id].flatMap { $0.window.object === window ? $0.passes : nil } ?? 0
            marks[id] = (.init(object: window), passes)
            let delta = passes - mark
            guard delta > 0 else { continue }
            let role = Self.role(of: window)
            frame[role, default: 0] += delta
        }
        guard records else { return }
        for (role, passes) in frame {
            var entry = roles[role] ?? Role()
            entry.passes += passes
            entry.frames += 1
            if passes >= 2 { entry.framesTwoOrMore += 1 }
            entry.max = Swift.max(entry.max, passes)
            roles[role] = entry
        }
        perFrame.append(frame)
    }

    /// `window`'s role: its own name, else "page window <number>" for a Chromium page child window, else its class and
    /// window number (stable while it lives).
    public static func role(of window: NSWindow) -> String {
        if let named = window as? LayoutPassRoleNaming { return named.layoutPassRole }
        if window.parent != nil, WindowOverlayHost.isPageWindow(window) { return "page window \(window.windowNumber)" }
        return "\(type(of: window)) \(window.windowNumber)"
    }
}
#endif
