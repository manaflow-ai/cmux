public import AppKit
import CmuxNextDesign

/// The Pair Another Machine card's panel: the same floating glass card as Add Server and Add Device
/// (``AddServerCardPanel``), near the top center of the cmux window, on every Space and over full
/// screen, never activating the app. Escape runs the card's Cancel.
///
/// SECURITY: Confirm pairs a machine into the person's account, so it answers only the person's own
/// click on it (``CmuxDialogPersonClick``, the join consent sheet's check): no key, Accessibility
/// press, programmatic click, posted click, script, MCP call or page reaches an approve.
@MainActor
public final class PairInviteCardPanel: NSPanel {
    public let model: PairInviteModel
    let content: PairInviteView
    private let glass: GlassPanelView
    /// SECURITY: Confirm answers only the person's own click on it, and, as Chrome's permission
    /// prompts guard, not a click begun within a double-click interval of the card drawing anew (the
    /// machine arrived and Confirm appeared under a pointer aimed at what was there before).
    let personClick = CmuxDialogPersonClick(activationDelay: NSEvent.doubleClickInterval)
    /// Whether an event is the person's own input (the app's strict source check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool {
        get { personClick.isPersonEvent }
        set { personClick.isPersonEvent = newValue }
    }
    /// The event the app is handling now (tests set it).
    var eventInHand: @MainActor () -> NSEvent? {
        get { personClick.eventInHand }
        set { personClick.eventInHand = newValue }
    }

    public init(model: PairInviteModel) {
        self.model = model
        content = PairInviteView(model: model)
        glass = Glass.makePanel(content: content, style: .regular, cornerRadius: 14)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: PairInviteView.width, height: 240)),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.pairInviteCard")
        glass.autoresizingMask = [.width, .height]
        contentView = glass
        content.onClose = { [weak self] in self?.orderOut(nil) }
        content.onResize = { [weak self] size in
            self?.fit(size)
            // Each redraw (an arrival, a refusal) arms the guard again.
            self?.personClick.shown()
        }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// Shows the card over `window` with the keys (it is always opened by a person) and mints a new
    /// invite. A card already showing a live invite keeps it.
    public func present(over window: NSWindow?) {
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        if !isVisible || model.phase == .idle {
            // task-owner: one mint per opening; close() or a newer mint supersedes it (its generation).
            Task { [model] in await model.mint() }
        }
        let size = content.fittingSize
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        setFrame(AddServerCardPanel.placement(size: size, over: window?.frame, in: visible), display: false)
        WindowActivation.show(self, .raise)
        personClick.shown()
    }

    override public func cancelOperation(_ sender: Any?) {
        if model.perform(.cancel) { orderOut(nil) }
    }

    /// Closing the card any other way stops its socket and countdown too.
    override public func orderOut(_ sender: Any?) {
        if model.phase != .idle { model.close() }
        super.orderOut(sender)
    }

    /// The card's own events: the person's click on Confirm is read from them.
    override public func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    /// SECURITY: Confirm answers here, from the person's click itself, never from the button's action.
    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        guard personClick.dispatch(event, allow: { [content] in content.confirmButton }, in: windowNumber, body) else { return }
        content.confirm()
    }

    /// Grows or shrinks downward, keeping the top edge where the person saw it.
    private func fit(_ size: NSSize) {
        guard size.height > 0, abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}
