import AppKit
import CmuxNextDesign

/// The appearance studio's window: a floating glass panel over the window
/// it customizes, as that window's child, so it moves with it and stays
/// above its Chromium page windows. Unlike a popover it stays open while
/// you click the window, which is the live preview. Drag its background to
/// move it; Esc, its close button or Customize Appearance again close it.
final class AppearanceStudioPanel: ActiveAppKeyPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        isMovable = true
        isMovableByWindowBackground = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.appearanceStudio")
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
