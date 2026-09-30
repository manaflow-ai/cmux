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
public enum WindowTitlebar {
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

    /// Whether `view`'s top edge is the window's top edge (a full-size
    /// content view with no titlebar strip above it).
    public static func isInTopRow(_ view: NSView) -> Bool {
        guard let window = view.window, let content = window.contentView else { return false }
        let frame = view.convert(view.bounds, to: nil)
        return frame.maxY >= content.convert(content.bounds, to: nil).maxY - 0.5
    }
}
