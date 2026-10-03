import AppKit
import CmuxNextDesign

final class AppearanceTunerPanel: ActiveAppKeyPanel {
    var onCancel: (() -> Void)?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.appearanceTuner")
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
