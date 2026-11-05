public import AppKit
import CmuxNextDesign

/// The one-time sheet of the join consent gate: the first request acpmux refused with
/// `consent_required` asks the person at this Mac once. A floating, non-activating glass panel at
/// the top right of the main screen, like Mac Screen's approval prompt: over every app and full
/// screen, never taking the keyboard or the frontmost app. Only a press on its buttons answers.
@MainActor
public final class JoinConsentAskPanel: NSPanel {
    /// Weak: the model's `present` owns this panel.
    weak var model: JoinConsentModel?
    let content: JoinConsentAskView
    /// SECURITY: Allow answers only the person's own click on it (``CmuxDialogPersonClick``).
    let personClick = CmuxDialogPersonClick()
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

    public init(model: JoinConsentModel) {
        self.model = model
        content = JoinConsentAskView(model: model)
        let glass = Glass.makePanel(content: content, style: .regular, cornerRadius: 14)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: JoinConsentAskView.width, height: 160)),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.joinConsentAsk")
        glass.autoresizingMask = [.width, .height]
        contentView = glass
    }

    /// The sheet's own events: the person's click on Allow is read from them (``CmuxDialogPersonClick``).
    override public func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    /// SECURITY: Allow answers here, from the person's click itself, never from the button's action: no
    /// Accessibility press, programmatic click or key reaches a grant, inside a dispatch or out of one.
    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        guard personClick.dispatch(event, allow: { [content] in content.allow }, in: windowNumber, body) else { return }
        // task-owner: one answer per click; the sheet hides at once and the write ends on its own
        Task { [weak model] in await model?.answer(allow: true) }
    }

    /// SECURITY: whether `up` ends the person's own click on `button`, taken once (``CmuxDialogPersonClick``).
    func takePersonClick(on button: NSView, up: NSEvent) -> Bool {
        personClick.takePersonClick(on: button, up: up, in: windowNumber)
    }

    /// Shows or hides the sheet (``JoinConsentModel/present``). It opens at once, with no fade.
    public func setShown(_ shown: Bool) {
        guard shown, model?.ask != nil else { return orderOut(nil) }
        animationBehavior = .none
        content.rebuild()
        let size = content.fittingSize
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(origin: .zero, size: size)
        setFrame(NSRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height),
                 display: true)
        orderFrontRegardless()
    }
}

/// The sheet's content (AppKit): who asked for what, the question, a note, Deny and Allow.
@MainActor
public final class JoinConsentAskView: NSView {
    static let width: CGFloat = 380
    /// Weak: the model's `present` owns the panel that owns this view.
    weak var model: JoinConsentModel?
    /// The Allow button now shown (``JoinConsentAskPanel/dispatch(_:_:)`` reads the person's click on it).
    private(set) weak var allow: NSControl?
    private let stack = NSStackView()

    public init(model: JoinConsentModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("cmux.joinConsentAsk.content")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space5, left: Metrics.space5, bottom: Metrics.space4, right: Metrics.space5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let model, let ask = model.ask else { return }
        let width = Self.width - 2 * Metrics.space5
        stack.addArrangedSubview(label(JoinConsentStrings.askTitle(ask), font: Typography.bodyEmphasized, color: Palette.textPrimary, width: width))
        stack.addArrangedSubview(label(JoinConsentStrings.askQuestion(ask.surface), font: Typography.body, color: Palette.textPrimary, width: width))
        stack.addArrangedSubview(label(JoinConsentStrings.askNote, font: Typography.caption, color: Palette.textSecondary, width: width))
        if let error = model.askError {
            stack.addArrangedSubview(label(error, font: Typography.caption, color: Palette.danger, width: width))
        }
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(button(JoinConsentStrings.deny, role: .cancel, allow: false, id: "cmux.joinConsentAsk.deny"))
        let allow = button(JoinConsentStrings.allow, role: .default, allow: true, id: "cmux.joinConsentAsk.allow")
        self.allow = allow
        row.addArrangedSubview(allow)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(row)
        layoutSubtreeIfNeeded()
    }

    private func button(_ title: String, role: CmuxDialogButton.Role, allow: Bool, id: String) -> NSControl {
        let spec = CmuxDialogButton(id: allow ? "allow" : "deny", title: title, role: role)
        let view = CmuxDialogButtonView(standalone: spec, target: self, action: allow ? #selector(allowPressed(_:)) : #selector(denyPressed))
        view.setAccessibilityIdentifier(id)
        // Both stay disabled while a write is in flight: no press lands over a grant still landing.
        view.isEnabled = model?.writing != true
        return view
    }

    /// SECURITY: a press of Allow through its action (an Accessibility press, a programmatic click, a key)
    /// answers nothing: only the person's own click on Allow allows, read by the panel from the click itself
    /// (``JoinConsentAskPanel/dispatch(_:_:)``).
    @objc func allowPressed(_ sender: NSView) {}
    // task-owner: one answer per press; the sheet hides at once and the write ends on its own
    @objc private func denyPressed() { Task { [weak model] in await model?.answer(allow: false) } }

    private func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        return field
    }
}
