import AppKit

extension Notification.Name {
    static let toggleNonNativeFullScreen = Notification.Name("cmux.toggleNonNativeFullScreen")
}

/// Manages non-native fullscreen for a window.
///
/// Instead of using macOS native fullscreen (which transitions to a new Space
/// and removes the desktop background), this resizes the window to fill the
/// screen while keeping it as a regular window. This preserves
/// `background-opacity` transparency since the desktop remains behind the window.
///
/// Unlike Ghostty's implementation which removes `.titled` from the styleMask,
/// cmux keeps `.titled` intact because it overlays SwiftUI controls (workspace +
/// button, notification bell, etc.) on the titlebar area. Removing `.titled`
/// breaks the AppKit hit-test chain and makes those controls unresponsive.
final class NonNativeFullscreen {

    // MARK: - Types

    enum Style {
        /// Standard non-native fullscreen: fills visible screen area.
        case nonNative
        /// Non-native fullscreen but keeps the menu bar visible.
        case visibleMenu
        /// Non-native fullscreen that pads the notch area on notched displays.
        case paddedNotch

        var hideMenu: Bool {
            switch self {
            case .nonNative: return true
            case .visibleMenu: return false
            case .paddedNotch: return true
            }
        }

        var paddedNotch: Bool {
            switch self {
            case .paddedNotch: return true
            default: return false
            }
        }
    }

    // MARK: - Saved State

    private struct SavedState {
        let frame: NSRect
    }

    // MARK: - State

    private var window: NSWindow?
    private var savedState: SavedState?
    private let style: Style

    var isFullScreen: Bool { savedState != nil }

    // MARK: - Init

    init(window: NSWindow, style: Style = .nonNative) {
        self.window = window
        self.style = style

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    func enter() {
        guard let window, !isFullScreen else { return }

        // If native fullscreen is active, exit it instead.
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }

        guard let screen = window.screen ?? NSScreen.main else { return }

        // Save state for restoration
        savedState = SavedState(frame: window.frame)

        // Auto-hide dock if visible
        if style.hideMenu {
            NSApp.presentationOptions.insert(.autoHideMenuBar)
        }
        if Self.screenHasDock(screen) {
            NSApp.presentationOptions.insert(.autoHideDock)
        }

        // Keep .titled so cmux's SwiftUI titlebar controls remain functional.
        // titlebarAppearsTransparent is already set, so the titlebar blends
        // with content seamlessly.
        window.setFrame(fullscreenFrame(for: screen), display: true, animate: true)
    }

    func exit() {
        guard let window, let saved = savedState else { return }

        // Restore presentation options
        NSApp.presentationOptions.remove(.autoHideMenuBar)
        NSApp.presentationOptions.remove(.autoHideDock)

        // Restore frame
        window.setFrame(saved.frame, display: true, animate: true)

        savedState = nil
    }

    func toggle() {
        if isFullScreen {
            exit()
        } else {
            enter()
        }
    }

    // MARK: - Window Events

    @objc private func windowWillClose(_ notification: Notification) {
        exit()
    }

    // MARK: - Private

    private func fullscreenFrame(for screen: NSScreen) -> NSRect {
        // Use the full screen frame since presentationOptions auto-hides
        // menu bar and dock. Subtract menu bar height because .titled is
        // still active and macOS won't let the window extend above it.
        var frame = screen.frame
        let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
        frame.size.height -= menuBarHeight

        if style.paddedNotch {
            let safeTop = screen.safeAreaInsets.top
            if safeTop > 0 {
                frame.size.height -= safeTop
            }
        }

        return frame
    }

    private static func screenHasDock(_ screen: NSScreen) -> Bool {
        // If the dock auto-hides, we don't need to hide it.
        if let dockAutohide = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool {
            if dockAutohide { return false }
        }

        // Check if visible frame is smaller than full frame (accounting for menu/notch)
        if screen.visibleFrame.width < screen.frame.width {
            return true
        }

        let menuHeight = NSApp.mainMenu?.menuBarHeight ?? 0
        let notchInset: CGFloat = screen.safeAreaInsets.top
        let boundaryAreaPadding: CGFloat = 5.0

        return screen.visibleFrame.height < (screen.frame.height - max(menuHeight, notchInset) - boundaryAreaPadding)
    }
}
