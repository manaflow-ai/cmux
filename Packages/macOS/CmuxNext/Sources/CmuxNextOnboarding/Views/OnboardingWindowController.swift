public import AppKit
public import CmuxNextDesign

/// The onboarding window: a transparent window whose step variants draw
/// their own Liquid Glass or opaque surface, with only a close button. Return continues, Escape skips the rest,
/// Command-[ goes back. Only Skip (Escape) or Done ends the flow; closing
/// the window otherwise leaves the first run unfinished, to resume later.
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: OnboardingModel
    /// Called once when the window has closed.
    public var onClose: (() -> Void)?
    /// Set while the App closes the window itself (`closeForRebuild`).
    private var closingForRebuild = false

    /// `variant` forces one screen design (the gallery's full-size preview).
    public init(model: OnboardingModel, variant: (any OnboardingScreenVariant.Type)? = nil) {
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
        window.animationBehavior = .alertPanel
        // The close button stays visible (Lane 20: every window of its own
        // shows it); Escape and Skip also dismiss.
        // A fixed size: content never grows the window.
        window.contentMinSize = OnboardingMetrics.windowSize
        window.contentMaxSize = OnboardingMetrics.windowSize
        window.identifier = NSUserInterfaceItemIdentifier("cmux.onboarding")
        super.init(window: window)
        window.delegate = self
        // Kind `.onboarding`: a clear window with only a close button; each
        // variant's surface draws its own glass or opaque background
        // (`OnboardingSurfaceView`).
        window.install(kind: .onboarding, content: OnboardingHostView(model: model, variant: variant), scope: .app)
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

    /// Closes the window for the App (a rebuild for another step), which is
    /// not the person's "not now".
    public func closeForRebuild() {
        closingForRebuild = true
        close()
    }

    public func windowWillClose(_ notification: Notification) {
        model.leave(notNow: !closingForRebuild)
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
        // A held key repeats: only a fresh press moves on (it must not also accept the password consent).
        case (36, []) where !event.isARepeat, (76, []) where !event.isARepeat: onKey?(.next)  // Return, Enter
        case (36, []), (76, []): break
        case (33, .command): onKey?(.back)                 // Command-[
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onKey?(.skipAll) }
}
