public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextDesignTokens

/// The consent card of "Computer use can act as me" (``AgentPaneActAsMe``): the only in-app way to
/// turn it on. The cmux dialog card in the floating dialog panel (``CmuxFloatingDialogPanel``) at the top
/// right of the main screen, as the join
/// consent sheet (``JoinConsentAskPanel``'s pattern): Allow answers only from the person's own click,
/// read from the click itself by the app's strict check (``PersonInputCheck``), never from the button's
/// action, so a click or key another process posts, an Accessibility press or DEBUG automation never
/// turns it on. Not Now and Turn Off take any press: closing and revoking need no proof. Like the join
/// consent sheet, it is left out of every capture cmux makes and Computer Use refuses it
/// (`sharingType = .none`, `CaptureExcludedWindows`).
@MainActor
public final class AgentPaneActAsMeCard: CmuxFloatingDialogPanel {
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
        super.init(identifier: "cmux.actAsMeCard")
        sharingType = .none
        content.close = { [weak self] in self?.hide() }
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
        hide()
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

    /// Shows the card (the cmux dialog card at the top right of the screen) with the grant's current state.
    public func show() {
        shownAt = ProcessInfo.processInfo.systemUptime
        content.rebuild()
        present(content)
    }
}

/// The card's content: the cmux dialog card with what the grant lets through, then Not Now (Escape) and Allow
/// (person-only: no key), or Turn Off (Return) while it is on.
@MainActor
public final class AgentPaneActAsMeCardView: CmuxDialogHostView {
    let grant: AgentPaneActAsMe
    var close: () -> Void = {}
    /// The Allow button now shown (``AgentPaneActAsMeCard/endClick(_:)`` reads the person's click on it).
    var allow: NSControl? { card?.buttonView("allow") }

    init(grant: AgentPaneActAsMe) {
        self.grant = grant
        super.init(frame: NSRect(x: 0, y: 0, width: 432, height: 180))
        setAccessibilityIdentifier("cmux.actAsMeCard.content")
        rebuild()
    }

    func rebuild() {
        let on = grant.isOn
        let buttons = on
            ? [CmuxDialogButton(id: "turnOff", title: AgentPaneActAsMeStrings.turnOff, role: .default)]
            : [CmuxDialogButton(id: "notNow", title: AgentPaneActAsMeStrings.notNow, role: .cancel),
               CmuxDialogButton(id: "allow", title: AgentPaneActAsMeStrings.allow, role: .default, personOnly: true)]
        let spec = CmuxDialogSpec(
            title: on ? AgentPaneActAsMeStrings.onTitle : AgentPaneActAsMeStrings.askTitle,
            lines: [AgentPaneActAsMeStrings.askBody,
                    grant.holder == .managed ? AgentPaneActAsMeStrings.managedNote : AgentPaneActAsMeStrings.askNote],
            buttons: buttons, identifier: "cmux.actAsMeCard.card")
        let card = draw(spec) { [weak self] id in
            switch id {
            case "notNow": self?.close()
            // Revoking needs no proof: any press turns it off.
            case "turnOff":
                self?.grant.turnOff()
                self?.close()
            // SECURITY: Allow's action turns nothing on (the card reads the person's click).
            default: break
            }
        }
        for id in ["turnOff", "notNow", "allow"] { card.buttonView(id)?.setAccessibilityIdentifier("cmux.actAsMeCard.\(id)") }
    }

    /// SECURITY: a press of Allow through its action (an Accessibility press, a programmatic click, a key)
    /// turns nothing on: only the person's own click does, read by the card (``AgentPaneActAsMeCard/endClick(_:)``).
    @objc func allowPressed(_ sender: NSView) {}
}

/// The pane's indicator while Computer use can act as me is on: a glass pill at the pane's top right that
/// says so, with Turn Off (any press revokes). Hidden while the grant is off. Follows the grant through
/// one observation task that ends with the pill (``stop()``, the pane's teardown).
@MainActor
final class AgentPaneActAsMeBadge: NSView {
    let grant: AgentPaneActAsMe
    private let text = ThemedLabel(labelWithString: "")
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
        // Fitted to the toast glass it draws on, in the theme's tint, again on every theme change.
        text.themeColor = { Palette.toastText(.primary) }
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
        String(localized: "agentPane.actAsMe.askTitle", defaultValue: "Let computer use act as you?", bundle: .localizedModule)
    }
    static var onTitle: String {
        String(localized: "agentPane.actAsMe.onTitle", defaultValue: "Computer use can act as you", bundle: .localizedModule)
    }
    static var askBody: String {
        String(localized: "agentPane.actAsMe.askBody",
               defaultValue: "Clicks and key presses an agent's computer use makes in a chat count as yours for Send, Retry and Approve. Nothing else: answering an agent's question or permission, changing a mode or trusting a folder still needs your own click.",
               bundle: .localizedModule)
    }
    static var askNote: String {
        String(localized: "agentPane.actAsMe.askNote",
               defaultValue: "Every action it lets through is logged with the app that made it. Turn it off at any time from the chat.",
               bundle: .localizedModule)
    }
    static var managedNote: String {
        String(localized: "agentPane.actAsMe.managedNote",
               defaultValue: "Your organization turned this on for this Mac. Turning it off lasts until cmux restarts.",
               bundle: .localizedModule)
    }
    static var allow: String { String(localized: "agentPane.actAsMe.allow", defaultValue: "Allow", bundle: .localizedModule) }
    static var notNow: String { String(localized: "agentPane.actAsMe.notNow", defaultValue: "Not Now", bundle: .localizedModule) }
    static var turnOff: String { String(localized: "agentPane.actAsMe.turnOff", defaultValue: "Turn Off", bundle: .localizedModule) }
    static var badge: String {
        String(localized: "agentPane.actAsMe.badge", defaultValue: "Computer use can act as you", bundle: .localizedModule)
    }
    static var badgeManaged: String {
        String(localized: "agentPane.actAsMe.badgeManaged", defaultValue: "Computer use can act as you (managed)", bundle: .localizedModule)
    }
}
