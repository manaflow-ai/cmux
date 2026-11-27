public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextDevices
import CmuxNextWakeups
public import Observation

/// The host's approval prompt for a device hub request (permission Ask):
/// who asks and what it could do, with Allow (remembered for that Mac: the
/// hub's Always at the scope asked for), Allow Only This Time and Not Now,
/// and the asking device's key to compare. A floating, non-activating panel at the top right of the main
/// screen: it shows over every app (full-screen ones too) and never takes
/// the keyboard or the frontmost app from the person. One request at a
/// time, in arrival order; a request the hub ends (revoked, timed out)
/// leaves the panel, and the panel gives up after the protocol's five
/// minutes on its own. It draws the one cmux dialog card on its glass
/// (``CmuxFloatingDialogPanel``), as every other prompt over every app does.
@MainActor @Observable
public final class MacScreenApprovalPrompt {
    /// The request on screen.
    public private(set) var current: SessionRequest?
    /// The last answer failed (the request ended meanwhile, the network).
    public private(set) var error: String?
    public private(set) var answering = false
    /// How long a request may wait (PROTOCOL.md: requests expire after 5 min).
    @ObservationIgnored var lifetime: Duration = .seconds(300)
    @ObservationIgnored var hub: @MainActor () -> DeviceHub? = { nil }
    /// Requests answered or expired here, which the hub may still list for a moment.
    @ObservationIgnored private var settled: Set<String> = []
    @ObservationIgnored private var panel: MacScreenApprovalPanel?
    @ObservationIgnored private let expiry = DemandTimer(owner: "mac-screen.approval-expiry")
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Shows and hides the panel; tests replace it.
    @ObservationIgnored var present: @MainActor (Bool) -> Void = { _ in }
    /// Where the card's answers go (``answer(_:)``); tests replace it.
    @ObservationIgnored var answerChoice: @MainActor (MacScreenApprovalChoice) -> Void = { _ in }
    /// SECURITY: whether an event is the person's own input (the app's strict source check,
    /// `PersonInputCheck`); with none set, none is, and no click allows.
    @ObservationIgnored public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false } {
        didSet { panel?.personClick.isPersonEvent = isPersonEvent }
    }
    /// The event the app is handling now (tests set it).
    @ObservationIgnored var eventInHand: @MainActor () -> NSEvent? = { NSApp.currentEvent } {
        didSet { panel?.personClick.eventInHand = eventInHand }
    }

    public init() {
        present = { [weak self] visible in self?.setPanelVisible(visible) }
        answerChoice = { [weak self] choice in self?.answer(choice) }
    }

    /// Follows `hub`'s pending requests from now on (nil: none).
    func follow(_ hub: DeviceHub?) {
        watch?.cancel()
        watch = nil
        settled = []
        update(hub?.pendingRequests ?? [])
        guard let hub else { return }
        watch = Task { [weak self] in
            for await requests in ObservationStream({ hub.pendingRequests }) {
                guard !Task.isCancelled else { return }
                self?.update(requests)
            }
        }
    }

    /// The hub's pending requests changed: show the oldest unanswered one.
    func update(_ requests: [SessionRequest]) {
        let open = requests.filter { !settled.contains($0.id) }
        let next = open.first { $0.id == current?.id } ?? open.first
        guard next?.id != current?.id else { return }
        current = next
        error = nil
        answering = false
        expiry.cancel()
        if let next {
            expiry.schedule(after: lifetime) { @MainActor [weak self] in
                guard let self, current?.id == next.id else { return }
                settled.insert(next.id)
                update(self.hub()?.pendingRequests ?? [])
            }
        }
        present(next != nil)
    }

    /// One of the prompt's buttons, for the request it was drawn for: an answer that lands after the
    /// next request took its place answers nothing (`requestID` names the request on the card).
    public func answer(_ choice: MacScreenApprovalChoice, for requestID: String? = nil) {
        guard let request = current, requestID == nil || requestID == request.id, let hub = hub(), !answering else { return }
        answering = true
        let (decision, scope, thenPermission) = choice.answer(requested: request.scope)
        // task-owner: one decision for the request on screen; the next request shows when it settles
        Task { [weak self] in
            do {
                try await hub.decide(request, decision: decision, scope: scope)
                if let thenPermission {
                    try await hub.setPermission(host: hub.identity.id, viewer: request.viewerId, scope: thenPermission)
                }
                self?.settle(request.id, hub: hub)
            } catch let failure as DeviceHubError where failure.code == .sessionNotPending || failure.code == .notFound {
                // It ended meanwhile (cancelled by the viewer, expired): nothing to answer.
                self?.settle(request.id, hub: hub)
            } catch {
                guard let self else { return }
                answering = false
                // retry-prompt-ok: answering a screen-share request is the person's decision (it lets another device see or control this Mac)
                self.error = L.t("macScreen.approval.failed", "The answer did not reach the device hub. Try again.")
            }
        }
    }

    func settle(_ id: String, hub: DeviceHub) {
        settled.insert(id)
        // Keep the old request until update observes the transition to no request. Clearing it
        // here made update's nil == nil guard skip closing the last request's panel.
        update(hub.pendingRequests)
    }

    // MARK: Panel

    /// Where the prompt's card shows; nil while hidden (tests).
    var panelFrame: CGRect? { panel?.cardFrame }

    /// The card shown now (tests).
    var dialogView: CmuxDialogView? { panel?.dialogView }

    /// The panel shown now (tests).
    var approvalPanel: MacScreenApprovalPanel? { panel }

    private func setPanelVisible(_ visible: Bool) {
        guard visible, let request = current else {
            // Closed, not only ordered out: its card holds this prompt, so an ordered-out panel
            // stayed in the app's window list for good. The next request makes a fresh one.
            panel?.hide()
            panel?.close()
            panel = nil
            return
        }
        let panel = self.panel ?? MacScreenApprovalPanel(prompt: self)
        self.panel = panel
        render(request, in: panel)
    }

    /// Draws `request` (with the last error) in the cmux dialog card, then follows the error and the answer in flight.
    private func render(_ request: SessionRequest, in panel: MacScreenApprovalPanel) {
        let shown = withObservationTracking {
            (error: error, answering: answering)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, let current = self.current, current.id == request.id else { return }
                self.render(current, in: panel)
            }
        }
        let spec = Self.spec(request, error: shown.error)
        if panel.dialogView?.spec != spec {
            // A new request (not a redraw of the one shown): a click aimed at what was there before is not taken.
            if panel.shownRequest != request.id {
                panel.shownRequest = request.id
                panel.personClick.shown()
            }
            panel.show(spec) { [weak self] id in
                // SECURITY: an Allow's action answers nothing (the panel reads the person's click); Deny takes any press.
                guard let choice = MacScreenApprovalChoice(rawValue: id), choice == .deny else { return }
                self?.answerChoice(choice)
            }
        }
        // No second answer while one is on its way.
        panel.dialogView?.setButtonsEnabled(!shown.answering)
    }

    /// The prompt as a cmux dialog. Leo, 2026-11-16: "super ugly", and "i dont want to have to click share this
    /// mac allow every single time". So: who asks and what it can do, in plain words, and what Allow keeps; the
    /// asking device's key to compare; a failed answer; then three answers stacked the card's width
    /// (``CmuxDialogSpec/Layout/stacked``): Allow first, which remembers this Mac (the hub's Always at the scope
    /// asked for), Allow Only This Time under it, and Not Now last as quiet text (Escape). The card has no Details
    /// disclosure, so Allow Only This Time is a further stacked button. SECURITY: both Allows are person-only (no
    /// key, no keycap): only the person's own click answers them (``MacScreenApprovalPanel``).
    static func spec(_ request: SessionRequest, error: String?) -> CmuxDialogSpec {
        let words = MacScreenApprovalWords(request)
        let fields: [CmuxDialogField] = request.viewerKeyFingerprint.map {
            [.code(label: MacScreenApprovalWords.deviceKey, text: fingerprintLines($0))]
        } ?? []
        func button(_ choice: MacScreenApprovalChoice, _ title: String, _ role: CmuxDialogButton.Role) -> CmuxDialogButton {
            CmuxDialogButton(id: choice.rawValue, title: title, role: role, personOnly: choice != .deny)
        }
        return CmuxDialogSpec(
            title: words.title,
            lines: [words.body, words.remembers],
            fields: fields,
            buttons: [button(words.allowChoice, MacScreenApprovalWords.allow, .default),
                      button(.once, MacScreenApprovalWords.onlyThisTime, .normal),
                      button(.deny, MacScreenApprovalWords.notNow, .cancel)],
            identifier: "macScreen.approval", layout: .stacked, error: error)
    }

    /// The fingerprint in two lines of four groups, so it reads and compares group by group against the other
    /// device's ("78BE 18E0 C08C 9C4D" over "7443 D95E 2DB6 8074").
    static func fingerprintLines(_ fingerprint: String) -> String {
        let groups = DeviceIdentity.displayFingerprint(fingerprint).split(separator: " ")
        let half = (groups.count + 1) / 2
        return [groups.prefix(half), groups.dropFirst(half)].filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }.joined(separator: "\n")
    }
}

/// The device-control prompt's floating panel. SECURITY: an Allow answers here, from the person's own click on it
/// (``CmuxDialogPersonClick``), never from the button's action: no Accessibility press, programmatic click, key
/// or click another process posts allows a device to see or control this Mac. A click that begins within the
/// double-click interval of the prompt showing, or of the person's previous click, is not taken.
@MainActor
final class MacScreenApprovalPanel: CmuxFloatingDialogPanel {
    private weak var prompt: MacScreenApprovalPrompt?
    let personClick = CmuxDialogPersonClick(activationDelay: { NSEvent.doubleClickInterval })
    /// The request whose card shows (a redraw of the same request keeps the activation delay's start).
    var shownRequest: String?

    init(prompt: MacScreenApprovalPrompt) {
        self.prompt = prompt
        super.init(identifier: "macScreen.approval.panel")
        // SECURITY: left out of every capture cmux makes and refused by Computer Use, as the join consent is: a shared
        // screen or an agent's capture never shows the Allow it could aim a posted click at.
        sharingType = .none
        // It shows looking like a window, so it drags like one by its glass and words (Leo, on the screen share card:
        // "it pops up looking like a window and you can't drag it around like one"). Its buttons keep their clicks.
        isMovableByPerson = true
        personClick.isPersonEvent = prompt.isPersonEvent
        personClick.eventInHand = prompt.eventInHand
    }

    override func sendEvent(_ event: NSEvent) {
        dispatch(event) { super.sendEvent(event) }
    }

    /// The panel's own dispatch of `event`; the person's click that ends on an Allow answers it, once.
    func dispatch(_ event: NSEvent, _ body: () -> Void) {
        let card = dialogView
        let allows = MacScreenApprovalChoice.allCases.filter { $0 != .deny }
        let control = personClick.dispatch(event, allows: { allows.compactMap { card?.buttonView($0.rawValue) } }, in: windowNumber, body)
        guard let control, let choice = allows.first(where: { card?.buttonView($0.rawValue) === control }) else { return }
        prompt?.answerChoice(choice)
    }
}

/// The approval prompt's words for one request, plain: who asks, what it can do, and what Allow
/// keeps (the app's card and cmux Remote's banner say the same).
nonisolated struct MacScreenApprovalWords: Equatable {
    let title: String
    let body: String
    let remembers: String
    /// Allow: the hub's Always at the scope asked for, so the next request of this Mac is not asked.
    let allowChoice: MacScreenApprovalChoice
    /// The asking device's key, grouped to compare (nil when the hub sent none).
    let key: String?

    init(_ request: SessionRequest) {
        let full = request.scope == .full
        title = String(format: full ? L.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
            : L.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName)
        body = full ? L.t("macScreen.approval.bodyFull", "It can see your screen and use your mouse and keyboard.")
            : L.t("macScreen.approval.bodyView", "It can see your screen but can’t control it.")
        remembers = String(format: full
            ? L.t("macScreen.approval.remembersFull", "Allow lets %@ control this Mac from now on. Change it in Devices.")
            : L.t("macScreen.approval.remembersView", "Allow lets %@ see this Mac from now on. Change it in Devices."), request.viewerName)
        allowChoice = full ? .alwaysFull : .alwaysView
        key = request.viewerKeyFingerprint.map(DeviceIdentity.displayFingerprint)
    }

    static var allow: String { L.t("macScreen.approval.allow", "Allow") }
    static var notNow: String { L.t("macScreen.approval.notNow", "Not Now") }
    static var deviceKey: String { L.t("macScreen.approval.deviceKey", "Device key") }
    static var onlyThisTime: String { L.t("macScreen.approval.onlyThisTime", "Allow Only This Time") }
}
