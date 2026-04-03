import AppKit

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
        /// Standard non-native fullscreen: hides dock and menu bar.
        case nonNative
        /// Non-native fullscreen but keeps the menu bar visible.
        case visibleMenu
        /// Non-native fullscreen that pads the notch area on notched displays.
        case paddedNotch
    }

    // MARK: - State

    private weak var window: NSWindow?
    private var savedState: SavedState?
    private let style: Style

    private(set) var isFullScreen: Bool = false

    // MARK: - Init

    init(window: NSWindow, style: Style = .nonNative) {
        self.window = window
        self.style = style
    }

    // MARK: - Public

    func enter() {
        guard let window, !isFullScreen else { return }

        // Save current state for restoration
        savedState = SavedState(
            styleMask: window.styleMask,
            frame: window.frame,
            level: window.level
        )

        // Hide dock (auto-hide so it can still be accessed by mousing to edge)
        if style != .visibleMenu {
            NSApp.presentationOptions.insert(.autoHideMenuBar)
        }
        NSApp.presentationOptions.insert(.autoHideDock)

        // Remove titlebar chrome but keep full-size content view
        window.styleMask.remove(.titled)
        window.styleMask.remove(.resizable)
        // Do NOT insert .fullScreen — that would trigger native fullscreen behavior
        // and cause transparency to be disabled.

        // Set window above normal level so it stays on top of the menu bar area
        window.level = .statusBar

        isFullScreen = true

        // Expand to fill screen after style changes take effect
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(self.fullscreenFrame(for: screen), display: true, animate: true)
        }
    }

    func exit() {
        guard let window, isFullScreen, let saved = savedState else { return }

        // Restore presentation options
        NSApp.presentationOptions.remove(.autoHideMenuBar)
        NSApp.presentationOptions.remove(.autoHideDock)

        // Restore window level
        window.level = saved.level

        // Restore styleMask
        window.styleMask = saved.styleMask

        // Restore frame
        DispatchQueue.main.async {
            window.setFrame(saved.frame, display: true, animate: true)
        }

        isFullScreen = false
        savedState = nil
    }

    func toggle() {
        if isFullScreen {
            exit()
        } else {
            enter()
        }
    }

    // MARK: - Private

    private func fullscreenFrame(for screen: NSScreen) -> NSRect {
        var frame = screen.frame

        switch style {
        case .nonNative:
            // Fill the entire screen
            break
        case .visibleMenu:
            // Leave room for the menu bar
            let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
            if menuBarHeight > 0 {
                frame.size.height -= menuBarHeight
            }
        case .paddedNotch:
            // Avoid the notch on displays that have one
            let safeTop = screen.safeAreaInsets.top
            if safeTop > 0 {
                frame.size.height -= safeTop
            }
        }

        return frame
    }
}

// MARK: - Saved State

private extension NonNativeFullscreen {
    struct SavedState {
        let styleMask: NSWindow.StyleMask
        let frame: NSRect
        let level: NSWindow.Level
    }
}
