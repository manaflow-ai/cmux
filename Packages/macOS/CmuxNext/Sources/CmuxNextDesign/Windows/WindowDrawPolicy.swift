public import AppKit

/// Why a surface does not draw now (`debug.surfaces` `paused`). A surface
/// that draws has no pause.
public nonisolated enum SurfacePause: String, Sendable {
    /// The surface is not in a window.
    case notInWindow = "not_in_window"
    /// Its window is not on screen (fully covered, another Space, display
    /// asleep, screen locked). Energy saving, not a defect: the surface
    /// draws its current content when the window is visible again.
    case windowOccluded = "window_occluded"
    /// The surface or an ancestor view is hidden.
    case hidden
    /// The App paused it (an unselected tab, an off-screen column).
    case suspended
}

/// The facts one drawing decision reads (``WindowDrawPolicy``).
public nonisolated struct SurfaceDrawInputs: Equatable, Sendable {
    public var inWindow: Bool
    /// `NSWindow.occlusionState` contains `.visible`. Key or active state
    /// plays no part: a visible window of an inactive app draws.
    public var windowVisible: Bool
    public var hidden: Bool
    public var suspended: Bool
    /// A consumer needs pixels whatever else holds (live hover mirrors).
    public var forced: Bool
    /// ``WindowDrawPolicy/drawsWhenOccluded`` holds for this launch.
    public var drawWhenOccluded: Bool

    public init(inWindow: Bool, windowVisible: Bool, hidden: Bool, suspended: Bool, forced: Bool = false,
                drawWhenOccluded: Bool = false) {
        self.inWindow = inWindow
        self.windowVisible = windowVisible
        self.hidden = hidden
        self.suspended = suspended
        self.forced = forced
        self.drawWhenOccluded = drawWhenOccluded
    }

    /// Why the surface must not draw, or nil when it draws.
    public var pause: SurfacePause? {
        if forced { return nil }
        guard inWindow else { return .notInWindow }
        if hidden { return .hidden }
        if suspended { return .suspended }
        if !windowVisible { return .windowOccluded }
        return nil
    }

    public var draws: Bool { pause == nil }
}

/// The one window-occlusion rule for every native drawing surface (Ghostty
/// terminals today) and for the blank-pane invariant.
///
/// Content in a window draws while AppKit reports the window at least partly
/// on screen (`occlusionState` contains `.visible`); nothing here guesses
/// visibility, and key or active state plays no part. While the window is
/// occluded, surfaces stop drawing (energy saving) and keep their state; when
/// it is visible again each surface draws its current content at once
/// (Ghostty's renderer draws on its `.visible` message).
///
/// Automation launches of DEBUG builds (`CMUX_NEXT_NO_ACTIVATE=1` or
/// `CMUX_NEXT_SOCKET_MODE=automation`, as the e2e scripts and GUI proofs
/// start the app on a host where it is never in front) keep occluded windows
/// drawing, so captures show content. The same rule as React pages
/// (`PageWebView.rendersWhenCovered`). Users keep the energy saving.
@MainActor
public enum WindowDrawPolicy {
    /// Whether a launch with `environment` draws occluded windows.
    nonisolated public static func isAutomationLaunch(_ environment: [String: String]) -> Bool {
        #if DEBUG
        return environment["CMUX_NEXT_NO_ACTIVATE"] == "1" || environment["CMUX_NEXT_SOCKET_MODE"] == "automation"
        #else
        return false
        #endif
    }

    /// Whether occluded windows draw in this launch (tests set it).
    public internal(set) static var drawsWhenOccluded = isAutomationLaunch(ProcessInfo.processInfo.environment)

    /// AppKit's answer: `occlusionState` contains `.visible`. Tests replace
    /// it to drive occlude and un-occlude transitions without a screen.
    static var onScreen: (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }

    /// Whether `window` is at least partly on screen now.
    public static func isOnScreen(_ window: NSWindow) -> Bool { onScreen(window) }

    /// Whether content in `window` may draw now (false without a window).
    public static func isDrawable(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return isOnScreen(window)
    }

    /// The drawing inputs of `view` now.
    public static func inputs(for view: NSView, suspended: Bool, forced: Bool = false) -> SurfaceDrawInputs {
        SurfaceDrawInputs(
            inWindow: view.window != nil,
            windowVisible: view.window.map(isOnScreen) ?? false,
            hidden: view.isHiddenOrHasHiddenAncestor,
            suspended: suspended,
            forced: forced,
            drawWhenOccluded: drawsWhenOccluded
        )
    }
}
