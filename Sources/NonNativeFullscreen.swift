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
/// When entering non-native fullscreen, `.titled` is removed from the styleMask
/// so the window can cover the full screen including the menu bar area. cmux's
/// titlebar controls (+ button, notification bell, etc.) are provided by
/// `fullscreenControls` — a SwiftUI view that appears in the content area when
/// `isFullScreen` is true, so they remain functional without NSTitlebarAccessoryViewControllers.
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
        savedState = SavedState(
            frame: window.frame,
            styleMask: window.styleMask
        )

        let firstResponder = window.firstResponder

        // Auto-hide dock and menu bar
        if Self.screenHasDock(screen) {
            NSApp.presentationOptions.insert(.autoHideDock)
        }
        if style.hideMenu {
            NSApp.presentationOptions.insert(.autoHideMenuBar)
        }

        // Remove .titled so the window can cover the full screen.
        window.styleMask.remove(.titled)
        window.styleMask.remove(.resizable)

        // Expand to fill screen. Dispatch async so styleMask changes settle.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.isFullScreen else { return }
            let targetFrame = self.fullscreenFrame(for: screen)
            window.setFrame(targetFrame, display: true)

            // Force SwiftUI's NSHostingView to recalculate layout for the
            // new contentLayoutRect after .titled removal and frame change.
            if let contentView = window.contentView {
                contentView.frame = window.contentRect(forFrameRect: targetFrame)
                contentView.needsLayout = true
                contentView.layoutSubtreeIfNeeded()
            }
            if let firstResponder {
                window.makeFirstResponder(firstResponder)
            }
        }
    }

    func exit() {
        guard let window, let saved = savedState else { return }

        let firstResponder = window.firstResponder

        // Restore presentation options
        NSApp.presentationOptions.remove(.autoHideMenuBar)
        NSApp.presentationOptions.remove(.autoHideDock)

        // Restore styleMask and frame
        window.styleMask = saved.styleMask
        window.setFrame(saved.frame, display: true, animate: true)

        // Force layout recalculation after restoring .titled
        if let contentView = window.contentView {
            contentView.frame = window.contentRect(forFrameRect: window.frame)
            contentView.needsLayout = true
            contentView.layoutSubtreeIfNeeded()
        }

        savedState = nil

        if let firstResponder {
            window.makeFirstResponder(firstResponder)
        }
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
            // Subtract menu bar height since we're keeping it visible
            let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
            frame.size.height -= menuBarHeight
        } else if style.paddedNotch {
            // Avoid the notch area
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
