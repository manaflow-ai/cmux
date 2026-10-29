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
    /// Whether an event is the person's own input (the app's strict source check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false }
    /// The person's own click on this sheet is being dispatched now: only then may Allow answer.
    private(set) var dispatchingPersonPress = false

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

    /// The sheet's own events: a mouse press the person made is marked for the length of its dispatch
    /// (the button's action runs inside it), so Allow can tell it from an Accessibility press or a call
    /// made outside it, which find no mark.
    override public func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        let press = [.leftMouseDown, .leftMouseUp].contains(event.type) && isPersonEvent(event)
        let outer = dispatchingPersonPress
        dispatchingPersonPress = outer || press
        defer { dispatchingPersonPress = outer }
        body()
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
        row.addArrangedSubview(button(JoinConsentStrings.allow, role: .default, allow: true, id: "cmux.joinConsentAsk.allow"))
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(row)
        layoutSubtreeIfNeeded()
    }

    private func button(_ title: String, role: CmuxDialogButton.Role, allow: Bool, id: String) -> NSView {
        let spec = CmuxDialogButton(id: allow ? "allow" : "deny", title: title, role: role)
        let view = CmuxDialogButtonView(standalone: spec, target: self, action: allow ? #selector(allowPressed) : #selector(denyPressed))
        view.setAccessibilityIdentifier(id)
        // Both stay disabled while a write is in flight: no press lands over a grant still landing.
        view.isEnabled = model?.writing != true
        return view
    }

    // task-owner: one answer per press; the sheet hides at once and the write ends on its own
    @objc func allowPressed() {
        // SECURITY: only the person's own click on this sheet, while the sheet dispatches it, allows. An
        // Accessibility press, a click another process (or DEBUG automation) posts, or a call from outside
        // that dispatch grants nothing, whatever event happens to be current.
        guard let model, (window as? JoinConsentAskPanel)?.dispatchingPersonPress == true else { return }
        Task { [weak model] in await model?.answer(allow: true) }
    }
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
