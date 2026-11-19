public import AppKit
public import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups
import os

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
    /// Reveals the window if the page has not painted by ``revealLimit``.
    private let revealDeadline = DemandTimer(owner: "onboarding.window.reveal")
    /// The longest the window stays transparent waiting for the page's first frame (the pane paint hold's limit).
    static let revealLimit: Duration = .milliseconds(500)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")
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
        case .agentTools: OnboardingStrings.agentToolsTitle
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
        // The page sits in a title row host: its row background reports presses there, and the
        // host moves the window (a Chromium page is a child window over the titlebar, so AppKit's
        // own titlebar drag never sees them).
        let content = TitleRowHostView(frame: NSRect(origin: .zero, size: size))
        content.autoresizingMask = [.width, .height]
        if let page {
            page.frame = content.bounds
            page.autoresizingMask = [.width, .height]
            content.addSubview(page)
        }
        window.install(kind: .onboarding, content: content, scope: .app, activeLook: activeLook)
        if model.step == .computerUse {
            helperPanels = ComputerUseHelperPanels(model: model.computerUse, window: window)
            helperPanels?.onForward = { [weak self] in self?.page?.focusPage() }
        }
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
    /// The window is transparent until the page paints its first frame (or ``revealLimit`` passes),
    /// so it never shows empty glass with the page popping in. It shows at once so the page paints.
    /// With no page (its bundle is missing) the window has nothing to show: it closes unshown, as
    /// its close button would (the step is left, not skipped or done), and nothing starts.
    public func present() {
        guard let window else { return }
        guard let page else {
            Self.logger.error("onboarding page did not load (\(self.model.step.rawValue, privacy: .public)): the window closes unshown")
            window.close()
            return
        }
        if !page.hasPainted {
            window.alphaValue = 0
            page.whenPainted { [weak self] in self?.reveal() }
            revealDeadline.schedule(after: Self.revealLimit) { @MainActor [weak self] in self?.reveal() }
        }
        WindowPlacement.present(window)
        leaveCloseButtonUncovered()
        page.focusPage()
        model.stepDidAppear()
    }

    /// Shows the transparent window (the page painted, or the limit passed); once.
    private func reveal() {
        revealDeadline.cancel()
        guard let window, window.alphaValue < 1 else { return }
        window.alphaValue = 1
    }

    /// A Chromium page is a child window over the whole window, the titlebar too (a full-size
    /// content view): it leaves the close button's rect uncovered, so the button shows and takes
    /// the click. WebKit draws under the titlebar and needs none. The window's size is fixed, so
    /// the rect is set once it is laid out.
    func leaveCloseButtonUncovered() {
        guard let page, let button = window?.standardWindowButton(.closeButton), let frame = button.superview else { return }
        page.nativeRects = [page.convert(button.frame, from: frame)]
    }

    /// The page's view, for tests.
    var pageView: NSView? { page }

    /// The rects the page leaves uncovered (``leaveCloseButtonUncovered()``), in window coordinates, for tests.
    var uncoveredRects: [CGRect] {
        guard let page else { return [] }
        return page.nativeRects.map { page.convert($0, to: nil) }
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
