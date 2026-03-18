import AppKit

/// A borderless floating NSPanel for the Quick Terminal.
final class QuickTerminalWindow: NSPanel {
    /// Allow the panel to become the key window so it can receive keyboard input.
    override var canBecomeKey: Bool { true }
    /// Allow the panel to become the main window for menu validation.
    override var canBecomeMain: Bool { true }

    /// Used to prevent SwiftUI hiccups from resizing the window during setup.
    var initialFrame: NSRect?

    /// Create a new Quick Terminal panel with the given content rect.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        identifier = .init(rawValue: "com.cmuxterm.quickTerminal")
        setAccessibilitySubrole(.floatingWindow)

        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        hasShadow = true
        animationBehavior = .none
    }

    /// Override to lock the frame during initial setup, preventing SwiftUI layout passes from resizing.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(initialFrame ?? frameRect, display: flag)
    }
}
