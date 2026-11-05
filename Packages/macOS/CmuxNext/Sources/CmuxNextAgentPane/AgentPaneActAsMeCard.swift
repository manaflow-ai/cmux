public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextDesignTokens

/// The consent card of "Computer use can act as me" (``AgentPaneActAsMe``): the only in-app way to
/// turn it on. A floating, non-activating glass panel at the top right of the main screen, as the join
/// consent sheet (``JoinConsentAskPanel``'s pattern): Allow answers only from the person's own click,
/// read from the click itself by the app's strict check (``PersonInputCheck``), never from the button's
/// action, so a click or key another process posts, an Accessibility press or DEBUG automation never
/// turns it on. Not Now and Turn Off take any press: closing and revoking need no proof.
@MainActor
public final class AgentPaneActAsMeCard: NSPanel {
    let grant: AgentPaneActAsMe
    let content: AgentPaneActAsMeCardView
    /// Whether an event is the person's own input (the app's strict source check); with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false }
    /// The event the app is handling now (tests set it).
    var eventInHand: @MainActor () -> NSEvent? = { NSApp.currentEvent }
    /// The person's own mouse-down on Allow, held until the click ends.
    private var personDown: (event: NSEvent, allow: NSControl)?
    /// The last mouse-up that answered Allow: each click answers once.
    private var spentUp: (number: Int, time: TimeInterval)?
    /// When ``show()`` put the card up (the events' clock, the system uptime); nil until it shows.
    var shownAt: TimeInterval?
    /// How long after the card shows a mouse-down on Allow is ignored: the card appears when an agent's Send
    /// is refused, so a click the person was already making elsewhere cannot land on Allow and turn it on.
    static let armDelay: TimeInterval = 0.5

    public init(grant: AgentPaneActAsMe) {
        self.grant = grant
        content = AgentPaneActAsMeCardView(grant: grant)
        let glass = Glass.makePanel(content: content, style: .regular, cornerRadius: Metrics.surfaceCornerRadius)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: AgentPaneActAsMeCardView.width, height: 180)),
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
        setAccessibilityIdentifier("cmux.actAsMeCard")
        glass.autoresizingMask = [.width, .height]
        contentView = glass
        content.close = { [weak self] in self?.orderOut(nil) }
    }

    override public func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        switch event.type {
        case .leftMouseDown:
            personDown = nil
            if let allow = content.allow, allow.isEnabled, isArmed(at: event.timestamp), isPersonEvent(event) {
                personDown = (event: event, allow: allow)
            }
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

    /// SECURITY: Allow turns the grant on here, from the person's click itself, never from the button's action.
    private func endClick(_ up: NSEvent) {
        defer { personDown = nil }
        guard let allow = content.allow, allow.isEnabled, takePersonClick(on: allow, up: up) else { return }
        grant.turnOn(.init())
        orderOut(nil)
    }

    /// SECURITY: whether `up` ends a click on `button` that is the person's own, taken once: the card holds
    /// the person's mouse-down on that same enabled button, and `up` is the person's mouse-up on it. A click
    /// another process posts, a click begun or ended elsewhere, and a click already taken find none.
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

    /// SECURITY: whether a mouse-down at `time` may begin a click on Allow: not within ``armDelay`` of ``show()``.
    func isArmed(at time: TimeInterval) -> Bool {
        shownAt.map { time - $0 >= Self.armDelay } ?? true
    }

    /// Shows the card (at once, no fade) with the grant's current state.
    public func show() {
        animationBehavior = .none
        shownAt = ProcessInfo.processInfo.systemUptime
        content.rebuild()
        let size = content.fittingSize
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(origin: .zero, size: size)
        setFrame(NSRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height),
                 display: true)
        orderFrontRegardless()
    }
}

/// The card's content: what the grant lets through, then Not Now and Allow, or Turn Off while it is on.
@MainActor
public final class AgentPaneActAsMeCardView: NSView {
    static let width: CGFloat = 380
    let grant: AgentPaneActAsMe
    var close: () -> Void = {}
    /// The Allow button now shown (``AgentPaneActAsMeCard/endClick(_:)`` reads the person's click on it).
    private(set) weak var allow: NSControl?
    private let stack = NSStackView()

    init(grant: AgentPaneActAsMe) {
        self.grant = grant
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 180))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("cmux.actAsMeCard.content")
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
        allow = nil
        let width = Self.width - 2 * Metrics.space5
        let on = grant.isOn
        stack.addArrangedSubview(label(on ? AgentPaneActAsMeStrings.onTitle : AgentPaneActAsMeStrings.askTitle,
                                       font: Typography.bodyEmphasized, color: Palette.textPrimary, width: width))
        stack.addArrangedSubview(label(AgentPaneActAsMeStrings.askBody, font: Typography.body, color: Palette.textPrimary, width: width))
        stack.addArrangedSubview(label(grant.holder == .managed ? AgentPaneActAsMeStrings.managedNote : AgentPaneActAsMeStrings.askNote,
                                       font: Typography.caption, color: Palette.textSecondary, width: width))
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        if on {
            row.addArrangedSubview(button(AgentPaneActAsMeStrings.turnOff, role: .default, id: "cmux.actAsMeCard.turnOff",
                                          action: #selector(turnOffPressed)))
        } else {
            row.addArrangedSubview(button(AgentPaneActAsMeStrings.notNow, role: .cancel, id: "cmux.actAsMeCard.notNow",
                                          action: #selector(notNowPressed)))
            let allow = button(AgentPaneActAsMeStrings.allow, role: .default, id: "cmux.actAsMeCard.allow", action: #selector(allowPressed(_:)))
            self.allow = allow
            row.addArrangedSubview(allow)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(row)
        layoutSubtreeIfNeeded()
    }

    private func button(_ title: String, role: CmuxDialogButton.Role, id: String, action: Selector) -> NSControl {
        let view = CmuxDialogButtonView(standalone: CmuxDialogButton(id: id, title: title, role: role), target: self, action: action)
        view.setAccessibilityIdentifier(id)
        return view
    }

    /// SECURITY: a press of Allow through its action (an Accessibility press, a programmatic click, a key)
    /// turns nothing on: only the person's own click does, read by the card (``AgentPaneActAsMeCard/endClick(_:)``).
    @objc func allowPressed(_ sender: NSView) {}
    @objc private func notNowPressed() { close() }
    /// Revoking needs no proof: any press turns it off.
    @objc private func turnOffPressed() {
        grant.turnOff()
        close()
    }

    private func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        return field
    }
}

/// The pane's indicator while Computer use can act as me is on: a glass pill at the pane's top right that
/// says so, with Turn Off (any press revokes). Hidden while the grant is off. Follows the grant through
/// one observation task that ends with the pill (``stop()``, the pane's teardown).
@MainActor
final class AgentPaneActAsMeBadge: NSView {
    let grant: AgentPaneActAsMe
    private let text = NSTextField(labelWithString: "")
    private var following: Task<Void, Never>?
    private var row: NSStackView?
    private var width: NSLayoutConstraint?
    private var height: NSLayoutConstraint?
    /// The pill showed, hid, resized or moved: a Chromium page (a window above the pane) leaves its rect
    /// uncovered (``AgentPaneView/applyNativeRects()``), so it stays visible and Turn Off takes clicks.
    var onFrameChange: (@MainActor () -> Void)?

    init(grant: AgentPaneActAsMe) {
        self.grant = grant
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("cmux.agentPane.actAsMe")
        text.font = Typography.caption
        text.textColor = Palette.textPrimary
        let turnOff = NSButton(title: AgentPaneActAsMeStrings.turnOff, target: self, action: #selector(turnOffPressed))
        turnOff.bezelStyle = .inline
        turnOff.controlSize = .small
        turnOff.setAccessibilityIdentifier("cmux.agentPane.actAsMe.turnOff")
        let row = NSStackView(views: [text, turnOff])
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        row.edgeInsets = NSEdgeInsets(top: Metrics.space1, left: Metrics.space3, bottom: Metrics.space1, right: Metrics.space2)
        let glass = Glass.makeSurface(.toast, content: row, cornerRadius: Metrics.surfaceCornerRadius)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.row = row
        width = widthAnchor.constraint(equalToConstant: 0)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([width, height].compactMap { $0 })
        render()
        // task-owner: the pill's `following`, cancelled in stop() with the pane
        following = Task { [weak self] in
            for await _ in ObservationStream({ [grant] in grant.holder }) {
                guard let self, !Task.isCancelled else { return }
                self.render()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func stop() {
        following?.cancel()
        following = nil
    }

    /// Sized from the filled label, so a holder change (the managed text is longer) still fits.
    private func render() {
        isHidden = !grant.isOn
        text.stringValue = grant.holder == .managed ? AgentPaneActAsMeStrings.badgeManaged : AgentPaneActAsMeStrings.badge
        if let row {
            let fit = row.fittingSize
            width?.constant = fit.width + 8
            height?.constant = fit.height
        }
        onFrameChange?()
    }

    override func layout() {
        super.layout()
        onFrameChange?()
    }

    /// A pane resize moves the pill without laying it out again.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onFrameChange?()
    }

    /// Revoking needs no proof: any press turns it off.
    @objc private func turnOffPressed() { grant.turnOff() }
}

/// The card's and the indicator's words.
enum AgentPaneActAsMeStrings {
    static var askTitle: String {
        String(localized: "agentPane.actAsMe.askTitle", defaultValue: "Let computer use act as you?", bundle: .module)
    }
    static var onTitle: String {
        String(localized: "agentPane.actAsMe.onTitle", defaultValue: "Computer use can act as you", bundle: .module)
    }
    static var askBody: String {
        String(localized: "agentPane.actAsMe.askBody",
               defaultValue: "Clicks and key presses an agent's computer use makes in a chat count as yours for Send, Retry and Approve. Nothing else: answering an agent's question or permission, changing a mode or trusting a folder still needs your own click.",
               bundle: .module)
    }
    static var askNote: String {
        String(localized: "agentPane.actAsMe.askNote",
               defaultValue: "Every action it lets through is logged with the app that made it. Turn it off at any time from the chat.",
               bundle: .module)
    }
    static var managedNote: String {
        String(localized: "agentPane.actAsMe.managedNote",
               defaultValue: "Your organization turned this on for this Mac. Turning it off lasts until cmux restarts.",
               bundle: .module)
    }
    static var allow: String { String(localized: "agentPane.actAsMe.allow", defaultValue: "Allow", bundle: .module) }
    static var notNow: String { String(localized: "agentPane.actAsMe.notNow", defaultValue: "Not Now", bundle: .module) }
    static var turnOff: String { String(localized: "agentPane.actAsMe.turnOff", defaultValue: "Turn Off", bundle: .module) }
    static var badge: String {
        String(localized: "agentPane.actAsMe.badge", defaultValue: "Computer use can act as you", bundle: .module)
    }
    static var badgeManaged: String {
        String(localized: "agentPane.actAsMe.badgeManaged", defaultValue: "Computer use can act as you (managed)", bundle: .module)
    }
}
