public import AppKit
public import CmuxNextWakeups

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
    /// An ancestor is parked without being hidden (``ParkingContainer``).
    case parked
    /// The App paused it (an unselected tab, an off-screen column).
    case suspended
    /// A frame hold covers it until the content parsed at its attach or swap is drawn (`TerminalFrameHold`): until
    /// that content is parsed the surface could only draw frames no one sees, so its first frame is that content.
    case awaitingContent = "awaiting_content"
}

/// The facts one drawing decision reads (``WindowDrawPolicy``). A surface reads each from a visibility node
/// (principled-audit restoreFrameHold R1/R2): one truth per surface, computed again on every edge of those nodes,
/// never from AppKit's view tree at draw time.
public nonisolated struct SurfaceDrawInputs: Equatable, Sendable {
    public var inWindow: Bool
    /// Its window's node is ``Visibility/visible`` (``WindowDrawPolicy/isDrawable(_:)`` reads the same node):
    /// AppKit's `occlusionState`, minimized, the app hidden or the displays asleep, and the window's
    /// ``WindowOcclusionFamily`` (one opaque cmux window covering it). Key or active state plays no part.
    public var windowVisible: Bool
    /// Its own node is hidden: AppKit hid the view or a container above it, its tab is not selected, its pane is
    /// suspended or its workspace hidden.
    public var hidden: Bool
    /// A container above is parked off screen but not hidden (``ParkingContainer``).
    public var parked: Bool
    public var suspended: Bool
    /// A consumer needs pixels whatever else holds (live hover mirrors).
    public var forced: Bool
    /// A frame hold waits for content not parsed yet (``SurfacePause/awaitingContent``); it wins over `forced`.
    public var awaitingContent: Bool
    /// ``WindowDrawPolicy/drawsWhenOccluded`` holds for this launch.
    public var drawWhenOccluded: Bool

    public init(inWindow: Bool, windowVisible: Bool, hidden: Bool, parked: Bool = false, suspended: Bool, forced: Bool = false,
                awaitingContent: Bool = false, drawWhenOccluded: Bool = false) {
        self.inWindow = inWindow
        self.windowVisible = windowVisible
        self.hidden = hidden
        self.parked = parked
        self.suspended = suspended
        self.forced = forced
        self.awaitingContent = awaitingContent
        self.drawWhenOccluded = drawWhenOccluded
    }

    /// Why the surface must not draw, or nil when it draws: a pure function of the inputs.
    public var pause: SurfacePause? {
        if !forced {
            guard inWindow else { return .notInWindow }
            if hidden { return .hidden }
            if parked { return .parked }
            if suspended { return .suspended }
            if !windowVisible, !drawWhenOccluded { return .windowOccluded }
        }
        return awaitingContent ? .awaitingContent : nil
    }

    public var draws: Bool { pause == nil }

    /// Its window is in this launch's sense off screen (miniaturized, another Space, covered, the app
    /// hidden or the displays asleep), whatever else pauses the surface: what
    /// ``WindowDrawPolicy/offScreenGPUReleaseDelay`` counts from.
    public var windowOffScreen: Bool { inWindow && !windowVisible && !drawWhenOccluded }

    /// In a window that is on screen: only this ends the release that
    /// ``WindowDrawPolicy/offScreenGPUReleaseDelay`` starts.
    public var windowOnScreen: Bool { inWindow && !windowOffScreen }
}

/// The one window-occlusion rule for every native drawing surface (Ghostty
/// terminals today) and for the blank-pane invariant.
///
/// Content in a window draws while the window's node (``WindowVisibilitySource``) is visible: AppKit reports
/// the window at least partly on screen (`occlusionState` contains `.visible`, not miniaturized, the rule of
/// ``visibility(of:)``) and its ``WindowOcclusionFamily`` does not call it covered. Terminals, this rule
/// (``isDrawable(_:)``) and the blank-pane invariant read that one node; key or active state plays no part.
/// While the window is
/// occluded, surfaces stop drawing (energy saving) and keep their state; when
/// it is visible again each surface draws its current content at once
/// (Ghostty's renderer draws on its `.visible` message).
///
/// Automation launches of DEBUG builds (`CMUX_NEXT_NO_ACTIVATE=1` or
/// `CMUX_NEXT_SOCKET_MODE=automation`, as the e2e scripts and GUI proofs
/// start the app on a host where it is never in front) keep occluded windows
/// drawing, so captures show content. The same rule as React pages
/// (`PageWebView.rendersWhenCovered`). Users keep the energy saving.
/// `CMUX_NEXT_BENCH_SHIPPING_DRAW=1` (idle-budget's shipping measurement
/// mode) gives an automation launch the user's draw (``drawsOccludedWindows(_:)``),
/// so an energy bench measures what users run. It changes only the draw:
/// the launch stays an automation launch for notifications and attention
/// (``isAutomationLaunch(_:)``).
@MainActor
public struct WindowDrawPolicy {
    public init() {}
    /// The environment key of the shipping measurement mode's draw.
    nonisolated public static let shippingDrawKey = "CMUX_NEXT_BENCH_SHIPPING_DRAW"

    /// Whether a launch with `environment` is an automation launch of a DEBUG build (e2e scripts, GUI
    /// proofs, benches). The draw rule starts from it; `DesktopNotifier` and the iPhone pairing's Dock
    /// bounce read it too.
    nonisolated public static func isAutomationLaunch(_ environment: [String: String]) -> Bool {
        #if DEBUG
        return environment["CMUX_NEXT_NO_ACTIVATE"] == "1" || environment["CMUX_NEXT_SOCKET_MODE"] == "automation"
        #else
        return false
        #endif
    }

    /// Whether a launch with `environment` draws occluded windows: an automation launch, unless it
    /// asks for the user's draw (``shippingDrawKey``).
    nonisolated public static func drawsOccludedWindows(_ environment: [String: String]) -> Bool {
        isAutomationLaunch(environment) && environment[shippingDrawKey] != "1"
    }

    /// How long a window stays off screen before the surfaces it shows let their GPU memory go;
    /// the first draw after it comes back makes them resident again. A hidden
    /// renderer frees its tiles at once in Chrome (`LayerTreeHostImpl::SetVisible(false)`,
    /// cc/trees/layer_tree_host_impl.cc); a window waits as long as a hidden page waits for its
    /// freeze (`browser.freezeHiddenTabs`), so a Space switch or Mission Control reallocates nothing.
    nonisolated public static let offScreenGPUReleaseDelay: Duration = .seconds(30)

    /// Whether occluded windows draw in this launch (tests set it).
    public internal(set) static var drawsWhenOccluded = drawsOccludedWindows(ProcessInfo.processInfo.environment)

    /// AppKit's live answer (``WindowVisibilitySource/appKitState(of:)``).
    /// Tests replace it to drive occlude and un-occlude transitions without a
    /// screen; the window's node reads it (``visibility(of:)``).
    static var onScreen: (NSWindow) -> Bool = { WindowVisibilitySource.appKitState(of: $0).isVisible }

    /// Whether AppKit reports `window` at least partly on screen now (not its occlusion family: ``isDrawable(_:)``).
    public static func isOnScreen(_ window: NSWindow) -> Bool { onScreen(window) }

    /// A window's own state as AppKit reports it, the default read of its node (``WindowVisibilitySource``):
    /// miniaturized is hidden, on screen (``isOnScreen(_:)``) is visible, otherwise occluded.
    public static func visibility(of window: NSWindow) -> Visibility {
        if window.isMiniaturized { return .hidden }
        return isOnScreen(window) ? .visible : .occluded
    }

    /// What ``WindowOcclusionRule`` reads about `window` now, AppKit's visibility through
    /// ``isOnScreen(_:)``. A window covers others when it hides what is under it, as Chrome's
    /// `-windowCanOccludeOtherWindows:` (web_contents_occlusion_checker_mac.mm) judges it.
    public static func occlusionFacts(of window: NSWindow) -> WindowOcclusionFacts {
        WindowOcclusionFacts(
            id: ObjectIdentifier(window), frame: window.frame, level: window.level.rawValue,
            isVisible: window.isVisible, isMiniaturized: window.isMiniaturized, systemVisible: isOnScreen(window),
            isActive: window.isKeyWindow || window.isMainWindow, canBecomeActive: window.canBecomeKey || window.canBecomeMain,
            paintsOpaque: window.alphaValue >= 1 && !window.ignoresMouseEvents
                && (window.isOpaque || window.backgroundColor.alphaComponent >= 1),
            ancestors: ancestors(of: window)
        )
    }

    /// `window`'s `parentWindow` chain, nearest first.
    private static func ancestors(of window: NSWindow) -> [ObjectIdentifier] {
        var chain: [ObjectIdentifier] = []
        var parent = window.parent
        while let next = parent {
            chain.append(ObjectIdentifier(next))
            parent = next.parent
        }
        return chain
    }

    /// Whether content in `window` may draw now (false without a window): its node is visible, the state its
    /// terminals' pause reads (``SurfaceDrawInputs/windowVisible``), occlusion family included, or this launch
    /// draws occluded windows.
    public static func isDrawable(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return drawsWhenOccluded || WindowVisibilitySource.of(window).node.isVisible
    }
}
