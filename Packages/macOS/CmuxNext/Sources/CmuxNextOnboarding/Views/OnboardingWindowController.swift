public import AppKit
public import CmuxNextDesign

/// The onboarding window: a compact, flat window in the theme's background
/// with only a close button. Return continues, Escape skips the rest,
/// Command-[ goes back. Closing it by any means ends the flow as skipped
/// unless the last step finished it.
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: OnboardingModel
    /// Called once when the window has closed.
    public var onClose: (() -> Void)?

    public init(model: OnboardingModel) {
        self.model = model
        let window = OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingMetrics.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = OnboardingStrings.windowTitle
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = Palette.windowBackground
        window.animationBehavior = .alertPanel
        window.identifier = NSUserInterfaceItemIdentifier("cmux.onboarding")
        ThemeStore.shared.adopt(window)
        super.init(window: window)
        window.delegate = self
        window.contentView = OnboardingRootView(model: model)
        window.onKey = { [weak model] key in
            switch key {
            case .next: model?.next()
            case .skipAll: model?.finish(completed: false)
            case .back: model?.back()
            }
        }
        model.onEnd = { [weak self] _ in self?.window?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window (placement and no-activate rules: `WindowPlacement`).
    public func present() {
        guard let window else { return }
        WindowPlacement.present(window)
        model.stepDidAppear()
    }

    public func windowWillClose(_ notification: Notification) {
        model.finish(completed: false)
        onClose?()
    }
}

/// Routes the flow's keys; everything else goes to the focused control.
final class OnboardingWindow: NSWindow {
    enum Key { case next, skipAll, back }
    var onKey: ((Key) -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (76, []): onKey?(.next)            // Return, Enter
        case (33, .command): onKey?(.back)                 // Command-[
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onKey?(.skipAll) }
}
