public import AppKit

/// `window.titlebar` in cmux.json.
/// `window.titlebarButtons` (R83): when the title bar's buttons (Back,
/// Forward, and later ones; never the sidebar toggle) show.
public nonisolated enum TitlebarButtonsMode: String, Sendable, CaseIterable, Codable {
    /// Hidden until the pointer is over the title bar row, then they fade
    /// in, in place (the default).
    case hover
    /// Always shown.
    case always
}

/// `tabs.plusButton` (R120): when each tab bar's plus button shows.
public nonisolated enum PlusButtonMode: String, Sendable, CaseIterable, Codable {
    /// Only while the tab bar is hovered (the default).
    case hover
    /// Always shown.
    case always
}

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

    /// A mouse-down on an empty titlebar area: a double-click runs the
    /// user's action, any other press moves the window with the pointer.
    public static func handleMouseDown(_ event: NSEvent, in window: NSWindow?) {
        if event.clickCount == 2 {
            performDoubleClick(in: window)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// The traffic lights' frame in window coordinates, or nil when they
    /// do not show (fullscreen, a window without them).
    public static func trafficLightsFrame(in window: NSWindow) -> CGRect? {
        guard !window.styleMask.contains(.fullScreen) else { return nil }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let frames = buttons.compactMap { type -> CGRect? in
            guard let button = window.standardWindowButton(type), !button.isHidden, button.window === window else { return nil }
            return button.convert(button.bounds, to: nil)
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
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
