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
/// cmux keeps `.titled` in the styleMask (removing it breaks SwiftUI's
/// NSHostingView coordinate mapping). With `.fullSizeContentView` already set
/// and `titlebarAppearsTransparent = true`, the content extends behind the
/// invisible titlebar, so setting the frame to `screen.frame` should give
/// effectively full-screen coverage.
final class NonNativeFullscreen {

    // MARK: - Types

    enum Style {
        /// Standard non-native fullscreen: fills entire screen, auto-hides menu bar and dock.
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

        // Auto-hide dock and menu bar via presentationOptions.
        if Self.screenHasDock(screen) {
            NSApp.presentationOptions.insert(.autoHideDock)
        }
        if style.hideMenu {
            NSApp.presentationOptions.insert(.autoHideMenuBar)
        }

        // Keep .titled — removing it breaks SwiftUI hit testing entirely.
        // With .fullSizeContentView + titlebarAppearsTransparent (both already
        // set by cmux), content extends behind the transparent titlebar.
        // Set frame to screen.frame so the window covers the full display.
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
        // Use screen.frame to cover the full display area.
        // .titled is kept but titlebar is transparent, so content fills visually.
        // presentationOptions auto-hides menu bar and dock.
        var frame = screen.frame

        if !style.hideMenu {
            let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
            frame.size.height -= menuBarHeight
        } else if style.paddedNotch {
            let safeTop = screen.safeAreaInsets.top
            if safeTop > 0 {
                frame.size.height -= safeTop
            }
        }

        return frame
    }

    private static func screenHasDock(_ screen: NSScreen) -> Bool {
        if let dockAutohide = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool {
            if dockAutohide { return false }
        }

        if screen.visibleFrame.width < screen.frame.width {
            return true
        }

        let menuHeight = NSApp.mainMenu?.menuBarHeight ?? 0
        let notchInset: CGFloat = screen.safeAreaInsets.top
        let boundaryAreaPadding: CGFloat = 5.0

        return screen.visibleFrame.height < (screen.frame.height - max(menuHeight, notchInset) - boundaryAreaPadding)
    }
}
