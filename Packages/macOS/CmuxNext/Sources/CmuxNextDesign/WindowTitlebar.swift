public import AppKit

/// `window.titlebar` in cmux.json.
public nonisolated enum TitlebarStyle: String, Sendable, CaseIterable, Codable {
    /// No titlebar strip (the default, user nxdog9): content reaches the
    /// window's top edge, the traffic lights sit in the top row, and every
    /// empty area of that row moves the window.
    case minimal
    /// A titlebar strip with the workspace name above the content.
    case standard
}

/// Titlebar behavior for the app's own drag areas (empty tab strip space,
/// the sidebar header, the titlebar strip), matching a native titlebar.
@MainActor
public struct WindowTitlebar {
    public init() {}
    /// What a titlebar double-click does: the user's macOS setting (System
    /// Settings > Desktop & Dock > "Double-click a window's title bar to").
    public enum DoubleClickAction: Equatable, Sendable {
        case zoom
        case minimize
        case none
    }

    /// Reads `AppleActionOnDoubleClick` ("Maximize", "Fill", "Minimize",
    /// "None"; the global domain), falling back to the older
    /// `AppleMiniaturizeOnDoubleClick`. macOS's default is zoom.
    public static func doubleClickAction(defaults: UserDefaults = .standard) -> DoubleClickAction {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        case "Maximize", "Fill": return .zoom
        default:
            return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? .minimize : .zoom
        }
    }

    /// Runs the titlebar double-click action on `window`.
    public static func performDoubleClick(in window: NSWindow?, action: DoubleClickAction = doubleClickAction()) {
        guard let window else { return }
        switch action {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }

    /// The last press `handleMouseDown` ran (window number, timestamp, click count).
    private static var handledPress: (Int, TimeInterval, Int)?

    /// A mouse-down on an empty titlebar area: a double-click runs the
    /// user's action, any other press moves the window with the pointer.
    /// One press runs once: a press on a view that handles its own titlebar
    /// row (Home's header strip) also reaches the window's `sendEvent`, and a
    /// second zoom put the window back where it was (Leo, cosmic-gray 2026-10-13).
    public static func handleMouseDown(_ event: NSEvent, in window: NSWindow?) {
        let press = (event.windowNumber, event.timestamp, event.clickCount)
        if let handledPress, handledPress == press { return }
        handledPress = press
        if event.clickCount == 2 {
            performDoubleClick(in: window)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// The traffic lights' frame in window coordinates, or nil when they
    /// do not show (fullscreen, a window without them).
    ///
    /// While a window leaves full screen AppKit lays it out at its windowed
    /// size before the lights are back in it (they are still in the full
    /// screen titlebar, and the style mask may still say full screen): a
    /// ``TrafficLightsResting`` window answers with the frame they come back
    /// to, so the top row lays out once, for where it rests, and does not
    /// jump when the animation ends (fullscreen-lag).
    public static func trafficLightsFrame(in window: NSWindow) -> CGRect? {
        // Before the style mask: it may still say full screen while the window shrinks back.
        if let resting = (window as? any TrafficLightsResting)?.restingTrafficLights { return resting }
        guard !window.styleMask.contains(.fullScreen) else { return nil }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let frames = buttons.compactMap { type -> CGRect? in
            guard let button = window.standardWindowButton(type), !button.isHidden, button.window === window else { return nil }
            return button.convert(button.bounds, to: nil)
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The main pane card's top inset in `root` (the window's root view):
    /// `gutter`, except under a minimal titlebar, where the top row's tab
    /// pills center on the traffic lights' line (never more than `gutter`;
    /// `PaneChromeMetrics.cardTop`).
    ///
    /// - Parameter clearsTrafficLights: The lights sit over the card and no
    ///   top-row strip makes room for them (tab bars at the bottom, no
    ///   sidebar under the lights): the card starts `gutter` below their row
    ///   (the lights and the toolbar band's buttons on their line).
    public static func cardTopInset(of root: NSView, minimal: Bool, gutter: CGFloat, clearsTrafficLights: Bool = false) -> CGFloat {
        guard minimal, let window = root.window, let lights = trafficLightsFrame(in: window) else { return gutter }
        let local = root.convert(lights, from: nil)
        if clearsTrafficLights {
            let row = max(local.height, TitlebarBandButton.side)
            return max(gutter, root.bounds.maxY - local.midY + row / 2 + gutter).rounded(.up)
        }
        // Floating panes keep the one even gap at the top too.
        guard !Metrics.floatingPanes else { return gutter }
        let centerFromTop = root.bounds.maxY - local.midY
        return min(gutter, PaneChromeMetrics.current.cardTop(centeringPillOn: centerFromTop, scale: window.backingScaleFactor))
    }

    /// Whether `view` sits in the window's titlebar band (a full-size
    /// content view in the top row, even when the layout pads it a few
    /// points below the window's top edge).
    public static func isInTopRow(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let band = TitlebarDragPolicy.bandRect(in: window)
        let frame = view.convert(view.bounds, to: nil)
        return band.height > 0 && frame.maxY > band.minY && frame.minY < band.maxY
    }
}

/// A window with a view in its top row after the traffic lights (an
/// incognito window's badge while the sidebar is hidden). Tab strips under
/// it start their tabs after it.
@MainActor
public protocol TitlebarAccessoryHosting: AnyObject {
    /// The accessory's frame in window coordinates, nil when none shows.
    var titlebarAccessoryFrame: CGRect? { get }
}

/// A window that knows where its traffic lights rest while AppKit has them
/// elsewhere (the end of a full screen exit). ``WindowTitlebar/trafficLightsFrame(in:)``
/// uses it when the window shows none of its own.
@MainActor
public protocol TrafficLightsResting: AnyObject {
    /// The lights' windowed frame in window coordinates while they are away
    /// for a transition, nil at any other time.
    var restingTrafficLights: CGRect? { get }
}
