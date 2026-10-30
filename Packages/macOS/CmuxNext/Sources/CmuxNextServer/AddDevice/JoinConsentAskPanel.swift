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
    /// The event the app is handling now (tests set it).
    var eventInHand: @MainActor () -> NSEvent? = { NSApp.currentEvent }
    /// The person's own mouse-down that began the click going on now, with the Allow button enabled when it
    /// came, held until the click ends: AppKit may hand a button the mouse-up in its tracking loop, inside
    /// the mouse-down's dispatch, or (the displayed, non-activating sheet) dispatch the mouse-up as an event
    /// of its own (HQ#5121). A click begun while Allow was disabled holds none.
    private var personDown: (event: NSEvent, allow: NSControl)?
    /// The last mouse-up that answered Allow: each click answers once.
    private var spentUp: (number: Int, time: TimeInterval)?

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

    /// The sheet's own events. The person's mouse-down is kept until its click ends: with the mouse-up's
    /// dispatch, or with the mouse-down's when a button took the mouse-up in its tracking loop there. A
    /// drag or pressure change while the button is held keeps it; any other event clears it. Where the
    /// click ends, the sheet reads it (``endClick(_:)``).
    override public func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        switch event.type {
        case .leftMouseDown:
            personDown = nil
            if let allow = content.allow, allow.isEnabled, isPersonEvent(event) { personDown = (event: event, allow: allow) }
            body()
            if let up = eventInHand(), up.type == .leftMouseUp { endClick(up) }
        case .leftMouseDragged, .pressure:
            body()
        case .leftMouseUp:
            body()
            endClick(event)
        default:
            personDown = nil
            body()
        }
    }

    /// SECURITY: Allow answers here, from the person's click itself, never from the button's action: no
    /// Accessibility press, programmatic click or key reaches a grant, inside a dispatch or out of one.
    private func endClick(_ up: NSEvent) {
        defer { personDown = nil }
        guard let allow = content.allow, allow.isEnabled, takePersonClick(on: allow, up: up) else { return }
        // task-owner: one answer per click; the sheet hides at once and the write ends on its own
        Task { [weak model] in await model?.answer(allow: true) }
    }

    /// SECURITY: whether `up` ends a click on `button` that is the person's own, taken once: the sheet
    /// holds the person's mouse-down on the button, taken while that same button was shown and enabled, and
    /// `up` is the person's mouse-up on it, not one taken before. A click another process (or DEBUG
    /// automation) posts, a click begun while Allow was disabled or on a button since rebuilt, a click begun
    /// or ended on anything else, and a click already taken find none.
    func takePersonClick(on button: NSView, up: NSEvent) -> Bool {
        guard let held = personDown, held.allow === button, up.type == .leftMouseUp, isPersonEvent(up) else { return false }
        let down = held.event
        guard up.windowNumber == windowNumber, down.windowNumber == windowNumber, up.timestamp >= down.timestamp else { return false }
        let inside = { (event: NSEvent) in button.bounds.contains(button.convert(event.locationInWindow, from: nil)) }
        guard inside(down), inside(up) else { return false }
        if let spent = spentUp, spent.number == up.eventNumber, spent.time == up.timestamp { return false }
        spentUp = (up.eventNumber, up.timestamp)
        return true
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
    /// The Allow button now shown (``JoinConsentAskPanel/endClick(_:)`` reads the person's click on it).
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
    /// (``JoinConsentAskPanel/endClick(_:)``).
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
