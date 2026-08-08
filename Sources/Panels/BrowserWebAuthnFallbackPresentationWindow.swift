import AppKit

@MainActor
final class BrowserWebAuthnFallbackPresentationWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.identifier = NSUserInterfaceItemIdentifier("cmux.browserWebAuthnFallbackPresentation")
        isReleasedWhenClosed = false
        isRestorable = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient, .ignoresCycle, .stationary]
        level = .normal
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
