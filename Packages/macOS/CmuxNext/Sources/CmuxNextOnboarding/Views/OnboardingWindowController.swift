public import AppKit
public import CmuxNextDesign
import CmuxNextPages

/// The tool window (Agents, Import from Browser, Computer Use setup): the
/// window's one glass backdrop with only a close button, and in it the
/// onboarding page (`webviews/src/pages/onboarding/`, served by
/// ``OnboardingPageProvider``). The page runs Return and Escape; the window
/// keeps them for when the page has no focus. Native beside the page: the
/// Computer Use helper drag panel (``ComputerUseHelperPanels``).
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: OnboardingModel
    private let page: PageWebView?
    private var helperPanels: ComputerUseHelperPanels?
    /// Called once when the window has closed.
    public var onClose: (() -> Void)?
    /// `activeLook`: the app's ``ActiveLookScope``, for the window's backdrop (nil follows the key state).
    public init(model: OnboardingModel, activeLook: ActiveLookScope?) {
        self.model = model
        let size = model.step.windowSize
        let window = OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = switch model.step {
        case .agents: OnboardingStrings.agentsTitle
        case .importData: OnboardingStrings.importTitle
        case .computerUse: OnboardingStrings.computerUseTitle
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = Motion.panes.animatesMovement ? .alertPanel : .none
        // The close button stays visible (Lane 20: every window of its own
        // shows it); Escape and Skip also dismiss.
        // A fixed size: content never grows the window.
        window.contentMinSize = size
        window.contentMaxSize = size
        window.identifier = NSUserInterfaceItemIdentifier("cmux.onboarding")
        let provider = OnboardingPageProvider(model: model)
        page = PageWebView(descriptor: .onboarding, routes: [PageRoute(prefix: "cmux.onboarding.", provider: provider)])
        super.init(window: window)
        window.delegate = self
        // Kind `.onboarding`: a clear window with only a close button over the window's one
        // backdrop (glass, or opaque under Reduce Transparency); the page draws no background.
        let content = page ?? NSView()
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        window.install(kind: .onboarding, content: content, scope: .app, activeLook: activeLook)
        if model.step == .computerUse { helperPanels = ComputerUseHelperPanels(model: model.computerUse, window: window) }
        window.onKey = { [weak model] key in
            switch key {
            case .next: model?.next()
            case .skipAll: model?.finish(completed: false)
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
        page?.focusPage()
        model.stepDidAppear()
    }

    /// Closes the window through its close button (the same AppKit path a
    /// click on it takes). Automation uses this.
    public func closeWithCloseButton() {
        guard let window else { return }
        if let button = window.standardWindowButton(.closeButton) { button.performClick(nil) } else { window.performClose(nil) }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        model.windowBecameKey()
    }

    public func windowWillClose(_ notification: Notification) {
        model.leave()
        helperPanels?.hidePanel()
        page?.close()
        onClose?()
    }
}

/// Routes the flow's keys; everything else goes to the focused control.
final class OnboardingWindow: NSWindow {
    enum Key { case next, skipAll }
    var onKey: ((Key) -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        // A held key repeats: only a fresh press moves on (it must not also accept the password consent).
        case (36, []) where !event.isARepeat, (76, []) where !event.isARepeat: onKey?(.next)  // Return, Enter
        case (36, []), (76, []): break
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onKey?(.skipAll) }
}
