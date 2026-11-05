public import AppKit
public import CmuxNextComputerUse
import CmuxNextDesign

/// The approval cards (docs/computer-use-approvals.md, Collectors): one cmux dialog per waiting
/// question, each in its own floating, non-activating panel at the top right of the main screen,
/// stacked downward. A card shows over every app and never takes the frontmost app or the
/// keyboard by itself; once the person clicks it, Escape denies. No key allows: Return has no
/// default and no allow has a Command key, so a stray keystroke never grants. Only a press on a card
/// answers from here, and none in the first ``ComputerUseApprovalPressGuard/delay`` after the card
/// shows or moves (a click or key meant for what was there a moment ago never answers it).
@MainActor
public final class ComputerUseApprovalCards: ComputerUseApprovalPresenting {
    /// One shown card.
    private struct Card {
        var dialog: Int
        var panel: NSPanel?
    }

    /// The cards' own dialog center: its host puts each dialog in its card panel.
    let center: CmuxDialogCenter
    private var cards: [String: Card] = [:]
    /// Card ids, oldest first (the stacking order).
    private var order: [String] = []
    /// Cards whose icon is still loading (withdrawn meanwhile: never shown).
    private var loading: Set<String> = []
    /// Builds a card's panel; tests pass nil to keep cards off screen.
    private let makesPanels: Bool
    /// The Computer Use setup card that shows (``ComputerUseRemoteSetupCard``), if any.
    var setupCard: ComputerUseRemoteSetupCard?

    public convenience init() {
        self.init(panels: true)
    }

    init(panels: Bool) {
        makesPanels = panels
        if panels {
            let host = ComputerUseApprovalCardHost()
            center = CmuxDialogCenter(host: host)
            host.placed = { [weak self] in self?.restack() }
        } else {
            center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        }
    }

    /// The dialog of question `id` (tests, automation), if its card shows.
    func dialogID(_ id: String) -> Int? { cards[id]?.dialog }

    public func show(_ pending: ComputerUseApprovalPending, broker: ComputerUseApprovalBroker) {
        if let card = cards[pending.id] {
            if let panel = card.panel as? ComputerUseApprovalCardPanel { panel.armPressGuard() }
            card.panel?.orderFrontRegardless()
            return
        }
        guard !loading.contains(pending.id) else { return }
        loading.insert(pending.id)
        let target = pending.request.target
        guard makesPanels else { return present(pending, icon: nil, broker: broker) }
        // task-owner: one icon read per card, off the main actor; a withdrawn card is not shown.
        Task { [weak self, weak broker] in
            let icon = await Task.detached(priority: .userInitiated) { Self.icon(for: target) }.value
            guard let self, let broker else { return }
            present(pending, icon: icon, broker: broker)
        }
    }

    public func withdraw(_ id: String) {
        loading.remove(id)
        guard let card = cards.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        _ = center.dismiss(card.dialog)
        card.panel?.close()
        restack()
    }

    private func present(_ pending: ComputerUseApprovalPending, icon: Data?, broker: ComputerUseApprovalBroker) {
        guard loading.remove(pending.id) != nil, broker.pending.contains(where: { $0.id == pending.id }) else { return }
        let id = pending.id
        place(id, spec: Self.spec(for: pending.request, icon: icon)) { [weak broker] decision in broker?.decide(id, decision: decision) }
    }

    /// Shows card `id` for `spec`; a press of one of the four answers runs `decide`, then the card closes.
    private func place(_ id: String, spec: CmuxDialogSpec, decide: @escaping @MainActor (ComputerUseApprovalDecision) -> Void) {
        placeCard(id, spec: spec, pressed: { button in
            if let decision = ComputerUseApprovalDecision(rawValue: button) { decide(decision) }
        })
    }

    /// Shows card `id` for `spec`; a press (never a dismissal) runs `pressed` with its button, then the card closes.
    func placeCard(_ id: String, spec: CmuxDialogSpec, pressed: @escaping @MainActor (String) -> Void) {
        let panel = makesPanels ? ComputerUseApprovalCardPanel.make() : nil
        let scope: CmuxDialogScope = panel.map { .window($0) } ?? .app
        let dialog = center.present(spec, in: scope) { [weak self] answer in
            guard let self, cards[id] != nil else { return }
            // Closed first, so `pressed` may show the next card in its place.
            withdraw(id)
            // A dismissal (the card withdrawn, its panel closed) decides nothing.
            if !answer.isDismissal { pressed(answer.button) }
        }
        cards[id] = Card(dialog: dialog, panel: panel)
        order.append(id)
        restack()
    }

    #if DEBUG
    /// Fixture cards shown (``showFixture(_:)``), by card id.
    private var fixtures: Set<String> = []

    /// DEBUG `debug.computer_use_card`: the real card for `request`, on no broker and no worker
    /// link. Any press or a dismissal only closes it: nothing is decided, saved or sent.
    /// Returns the card's id.
    @discardableResult
    public func showFixture(_ request: ComputerUseApprovalRequest) -> String {
        let id = "fixture-" + request.id
        guard cards[id] == nil, !loading.contains(id) else { return id }
        fixtures.insert(id)
        guard makesPanels else {
            place(id, spec: Self.spec(for: request, icon: nil)) { _ in }
            return id
        }
        loading.insert(id)
        let target = request.target
        // task-owner: one icon read for the fixture card, off the main actor; a dismissed fixture is not shown.
        Task { [weak self] in
            let icon = await Task.detached(priority: .userInitiated) { Self.icon(for: target) }.value
            guard let self, loading.remove(id) != nil else { return }
            place(id, spec: Self.spec(for: request, icon: icon)) { _ in }
        }
        return id
    }

    /// Closes every fixture card (as a dismissal: it decides nothing); returns how many were open or loading.
    @discardableResult
    public func dismissFixtures() -> Int {
        let open = fixtures.filter { cards[$0] != nil || loading.contains($0) }
        for id in fixtures { withdraw(id) }
        fixtures = []
        return open.count
    }

    /// A fixture question as a worker would ask it: Claude in workspace "api-server" wants to use
    /// Safari, from `client` (this app's bundle id), answerable for 10 minutes from `nowMs`
    /// (nil only for a client that is not a JSON string).
    public static func fixtureRequest(client: String, nowMs: Int64) -> ComputerUseApprovalRequest? {
        var object: [String: Any] = [
            "v": 1, "nonce": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), "client": client,
            "machine": "fixture", "session": "fixture", "agent": "Claude", "workspace": "api-server",
            "target": ["bundle_id": "com.apple.Safari", "executable": NSNull(), "name": "Safari"] as [String: Any],
            "tool": "click", "risk": "R1",
            "created_ms": nowMs, "wait_until_ms": nowMs + 120_000, "answerable_until_ms": nowMs + 600_000,
        ]
        guard let canonical = ComputerUseCanonicalJSON(foundation: object) else { return nil }
        object["digest"] = ComputerUseApprovalRequest.digest(of: canonical)
        return ComputerUseApprovalRequest(object)
    }
    #endif

    /// The card's dialog: who asks (agent, workspace, cmux client), the app (icon and name),
    /// until when, and the four answers.
    static func spec(for request: ComputerUseApprovalRequest, icon: Data?, timeZone: TimeZone = .current) -> CmuxDialogSpec {
        let app = request.target.name.isEmpty ? (request.target.bundleID ?? request.target.executable ?? "") : request.target.name
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let until = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(request.answerableUntilMs) / 1000))
        return CmuxDialogSpec(
            title: ComputerUseApprovalStrings.title(agent: request.agent, app: app),
            lines: [ComputerUseApprovalStrings.asker(agent: request.agent, workspace: request.workspace),
                    request.target.bundleID ?? request.target.executable ?? "",
                    ComputerUseApprovalStrings.client(request.client),
                    ComputerUseApprovalStrings.expires(until)],
            // Four answers do not fit one row of the card (a row drops the first, Deny): one per
            // line, the narrowest grant first and Deny last, where the eye ends.
            buttons: [
                // No Return default and no Command key on an allow: a stray key never grants.
                CmuxDialogButton(id: ComputerUseApprovalDecision.once.rawValue, title: ComputerUseApprovalStrings.allowOnce, role: .normal),
                CmuxDialogButton(id: ComputerUseApprovalDecision.session.rawValue, title: ComputerUseApprovalStrings.allowSession, role: .normal),
                CmuxDialogButton(id: ComputerUseApprovalDecision.always.rawValue, title: ComputerUseApprovalStrings.allowAlways(app), role: .normal),
                CmuxDialogButton(id: ComputerUseApprovalDecision.deny.rawValue, title: ComputerUseApprovalStrings.deny, role: .cancel),
            ],
            icon: icon,
            identifier: ComputerUseApprovalService.approvalDialogIdentifier,
            buttonLayout: .column)
    }

    /// The target app's icon as TIFF data, nil when it cannot be found.
    nonisolated static func icon(for app: ComputerUseApprovalApp) -> Data? {
        let workspace = NSWorkspace.shared
        let path = app.bundleID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0)?.path } ?? app.executable
        guard let path else { return nil }
        let image = workspace.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        return image.tiffRepresentation
    }

    /// Places the cards at the top right of the main screen, oldest on top.
    private func restack() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        var top = area.maxY - 16
        for id in order {
            guard let panel = cards[id]?.panel, let content = panel.contentView else { continue }
            let size = content.fittingSize
            let frame = CGRect(x: area.maxX - size.width - 16, y: top - size.height, width: size.width, height: size.height)
            // A card that appears or moves takes no press for a moment.
            if panel.frame != frame || !panel.isVisible, let card = panel as? ComputerUseApprovalCardPanel { card.armPressGuard() }
            panel.setFrame(frame, display: true)
            top = frame.minY - 8
            panel.orderFrontRegardless()
        }
    }
}

/// A card's panel: floating over every app and Space, non-activating. It may become key only
/// after the person clicked in it (so its keys work then): a card never takes the keyboard on its
/// own, also not when another card closes and AppKit picks the next key window.
@MainActor
final class ComputerUseApprovalCardPanel: NSPanel {
    private var clicked = false
    private var pressGuard = ComputerUseApprovalPressGuard()
    /// The clock the guard arms by: system uptime, the clock `NSEvent.timestamp` is in (tests inject one).
    var now: () -> TimeInterval = { ComputerUseApprovalCardPanel.uptime() }
    override var canBecomeKey: Bool { clicked }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // A press in the guard's window is dropped whole: no button tracks it, and it does not
        // make the card key either.
        // Review 2 #10: by when the press happened, not when the main thread got to it, so a
        // stalled main thread cannot let an early click through.
        guard delivers(event.type, at: event.timestamp) else { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown { clicked = true }
        super.sendEvent(event)
    }

    /// The card showed or moved now: presses wait out the guard's delay.
    func armPressGuard() { pressGuard.arm(at: now()) }

    /// Whether an event of `type` made at `timestamp` (system uptime, `NSEvent.timestamp`) reaches the card.
    func delivers(_ type: NSEvent.EventType, at timestamp: TimeInterval) -> Bool { pressGuard.admits(type, at: timestamp) }

    /// Seconds since the system started, the clock of `NSEvent.timestamp`.
    nonisolated static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func make(now: @escaping () -> TimeInterval = { ComputerUseApprovalCardPanel.uptime() }) -> ComputerUseApprovalCardPanel {
        let panel = ComputerUseApprovalCardPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
                                                 styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.now = now
        panel.armPressGuard()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// Review 1 #8: a card can appear (or move up when another one closes) under a click or a key
/// already on its way; that press must not answer it. For ``delay`` after the card shows or
/// moves, mouse-down and key-down events are dropped. Times are system uptime: the arm time
/// read when the card shows or moves, and each event's own timestamp (no sleeps).
struct ComputerUseApprovalPressGuard {
    static let delay: TimeInterval = 0.6
    /// The event types that can press a card's button.
    static let presses: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    private var armedAt: TimeInterval?

    mutating func arm(at now: TimeInterval) { armedAt = now }

    func admits(_ type: NSEvent.EventType, at timestamp: TimeInterval) -> Bool {
        guard Self.presses.contains(type), let armedAt else { return true }
        return timestamp - armedAt >= Self.delay
    }
}

/// Puts each card's dialog view in its own panel (the scope's window).
@MainActor
final class ComputerUseApprovalCardHost: CmuxDialogHosting {
    /// A card was placed or removed: the cards restack.
    var placed: () -> Void = {}

    func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        guard case .window(let panel) = scope else { return }
        dialog.layoutSubtreeIfNeeded()
        let size = dialog.fittingSize
        dialog.translatesAutoresizingMaskIntoConstraints = true
        dialog.autoresizingMask = [.width, .height]
        dialog.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(dialog)
        panel.contentView = container
        // The card is in no cmux window: its content takes the app theme once it is the panel's
        // content (as the permission panel does), else the dialog keeps another theme's ink on a
        // grey slab (cx-ujp; seen on a capture of the fleet build).
        ThemeScope.app.store.adopt(panel)
        panel.setContentSize(size)
        placed()
    }

    func hide(_ dialog: CmuxDialogView) {
        dialog.window?.orderOut(nil)
        dialog.removeFromSuperview()
        placed()
    }
}
