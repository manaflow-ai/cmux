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
/// Modeled after Ghostty's `Fullscreen.swift` implementation.
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
        let styleMask: NSWindow.StyleMask
        let titlebarAccessoryViewControllers: [NSTitlebarAccessoryViewController]
        let toolbar: NSToolbar?
        let toolbarStyle: NSWindow.ToolbarStyle
        let hasDock: Bool
        let hideMenu: Bool
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

        // Determine whether to hide dock and menu
        let hasDock = Self.screenHasDock(screen)
        let hideMenu = style.hideMenu

        // Save state for restoration
        let accessories: [NSTitlebarAccessoryViewController] = window.styleMask.contains(.titled)
            ? window.titlebarAccessoryViewControllers
            : []
        savedState = SavedState(
            frame: window.frame,
            styleMask: window.styleMask,
            titlebarAccessoryViewControllers: accessories,
            toolbar: window.toolbar,
            toolbarStyle: window.toolbarStyle,
            hasDock: hasDock,
            hideMenu: hideMenu
        )

        let firstResponder = window.firstResponder

        // Hide dock (must be done before hiding menu)
        if hasDock {
            NSApp.presentationOptions.insert(.autoHideDock)
        }

        // Hide menu bar
        if hideMenu {
            NSApp.presentationOptions.insert(.autoHideMenuBar)
        }

        // Remove titled style so content fills the full frame
        window.styleMask.remove(.titled)
        window.styleMask.remove(.resizable)

        window.makeKeyAndOrderFront(nil)

        // Set frame async so style changes take effect first
        DispatchQueue.main.async { [self] in
            window.setFrame(self.fullscreenFrame(for: screen), display: true)
            if let firstResponder {
                window.makeFirstResponder(firstResponder)
            }
        }
    }

    func exit() {
        guard let window, let saved = savedState else { return }

        let firstResponder = window.firstResponder

        // Unhide dock
        if saved.hasDock {
            NSApp.presentationOptions.remove(.autoHideDock)
        }

        // Unhide menu bar
        if saved.hideMenu {
            NSApp.presentationOptions.remove(.autoHideMenuBar)
        }

        // Restore window state
        window.styleMask = saved.styleMask
        window.setFrame(saved.frame, display: true)

        // Restore titlebar accessories (removed when .titled was stripped)
        for controller in saved.titlebarAccessoryViewControllers {
            if window.titlebarAccessoryViewControllers.firstIndex(of: controller) == nil {
                window.addTitlebarAccessoryViewController(controller)
            }
        }

        // Restore toolbar
        window.toolbar = saved.toolbar
        window.toolbarStyle = saved.toolbarStyle

        if let firstResponder {
            window.makeFirstResponder(firstResponder)
        }

        savedState = nil

        window.makeKeyAndOrderFront(nil)
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
        var frame = screen.frame

        if !style.hideMenu {
            // Subtract menu bar height since we're still showing it
            frame.size.height -= NSApp.mainMenu?.menuBarHeight ?? 0
        } else if style.paddedNotch {
            // Avoid the notch area
            frame.size.height -= screen.safeAreaInsets.top
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
