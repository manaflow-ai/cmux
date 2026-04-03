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
        /// Standard non-native fullscreen: fills visible screen area.
        case nonNative
        /// Non-native fullscreen but keeps the menu bar visible.
        case visibleMenu
        /// Non-native fullscreen that pads the notch area on notched displays.
        case paddedNotch
    }

    // MARK: - State

    private var window: NSWindow?
    private var savedFrame: NSRect?
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

        // Save current frame for restoration
        savedFrame = window.frame

        isFullScreen = true

        // Expand to fill screen
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(fullscreenFrame(for: screen), display: true, animate: true)
    }

    func exit() {
        guard let window, isFullScreen, let saved = savedFrame else { return }

        // Restore frame
        window.setFrame(saved, display: true, animate: true)

        isFullScreen = false
        savedFrame = nil
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
        switch style {
        case .nonNative:
            // Fill the entire visible area (excludes menu bar and dock)
            return screen.visibleFrame
        case .visibleMenu:
            // Same as nonNative — visibleFrame already preserves menu bar
            return screen.visibleFrame
        case .paddedNotch:
            // Use visible frame but also avoid the notch area
            var frame = screen.visibleFrame
            let safeTop = screen.safeAreaInsets.top
            if safeTop > 0 {
                frame.size.height -= safeTop
            }
            return frame
        }
    }
}
