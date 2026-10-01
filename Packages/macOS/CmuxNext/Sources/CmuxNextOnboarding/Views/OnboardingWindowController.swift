public import AppKit
public import CmuxNextDesign

/// The onboarding window: one Liquid Glass surface (opaque theme background
/// under Reduce Transparency) with only a close button. Return continues, Escape skips the rest,
/// Command-[ goes back. Closing it by any means ends the flow as skipped
/// unless the last step finished it.
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    public let model: OnboardingModel
    /// Called once when the window has closed.
    public var onClose: (() -> Void)?
    private var tintLoop: RenderLoop?

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
        window.animationBehavior = .alertPanel
        // A fixed size: content never grows the window.
        window.contentMinSize = OnboardingMetrics.windowSize
        window.contentMaxSize = OnboardingMetrics.windowSize
        window.identifier = NSUserInterfaceItemIdentifier("cmux.onboarding")
        ThemeStore.shared.adopt(window)
        super.init(window: window)
        window.delegate = self
        let root = OnboardingRootView(model: model)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            // Reduce Transparency: the same layout on an opaque theme background.
            window.backgroundColor = Palette.windowBackground
            window.contentView = root
        } else {
            // One real Liquid Glass surface for the whole window.
            window.isOpaque = false
            window.backgroundColor = .clear
            let glass = Glass.makePanel(content: root, cornerRadius: 0)
            glass.translatesAutoresizingMaskIntoConstraints = true
            glass.autoresizingMask = [.width, .height]
            window.contentView = glass
            // The content carries the theme background at partial alpha over
            // the glass, so a light theme reads light over any desktop (also
            // in an inactive window, where the glass tint is not drawn).
            root.wantsLayer = true
            tintLoop = RenderLoop { [weak root] in
                _ = ThemeStore.shared.input
                root?.layer?.backgroundColor = Palette.windowBackground.withAlphaComponent(Self.glassTintAlpha).cgColor
            }
        }
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

    /// How much of the theme background the glass carries (the rest is the
    /// blurred desktop).
    static let glassTintAlpha: CGFloat = 0.7

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
