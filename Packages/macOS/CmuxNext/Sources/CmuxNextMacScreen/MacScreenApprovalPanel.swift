import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextDevices
import CmuxNextWakeups
public import Observation

/// The host's approval prompt for a device hub request (permission Ask):
/// the viewer device's name and key fingerprint and the scope it asks for,
/// with Deny, Allow Once, Always Allow View Only and Always Allow Full
/// Control. A floating, non-activating panel at the top right of the main
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
    @ObservationIgnored private var panel: CmuxFloatingDialogPanel?
    @ObservationIgnored private let expiry = DemandTimer(owner: "mac-screen.approval-expiry")
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Shows and hides the panel; tests replace it.
    @ObservationIgnored var present: @MainActor (Bool) -> Void = { _ in }

    public init() {
        present = { [weak self] visible in self?.setPanelVisible(visible) }
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

    /// One of the prompt's buttons.
    public func answer(_ choice: MacScreenApprovalChoice) {
        guard let request = current, let hub = hub(), !answering else { return }
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

    private func setPanelVisible(_ visible: Bool) {
        guard visible, let request = current else {
            // Closed, not only ordered out: its card holds this prompt, so an ordered-out panel
            // stayed in the app's window list for good. The next request makes a fresh one.
            panel?.hide()
            panel?.close()
            panel = nil
            return
        }
        let panel = self.panel ?? CmuxFloatingDialogPanel(identifier: "macScreen.approval.panel")
        self.panel = panel
        render(request, in: panel)
    }

    /// Draws `request` (with the last error) in the cmux dialog card, then follows the error and the answer in flight.
    private func render(_ request: SessionRequest, in panel: CmuxFloatingDialogPanel) {
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
            panel.show(spec) { [weak self] id in
                guard let choice = MacScreenApprovalChoice(rawValue: id) else { return }
                self?.answer(choice)
            }
        }
        // No second answer while one is on its way.
        panel.dialogView?.setButtonsEnabled(!shown.answering)
    }

    /// The prompt as a cmux dialog: who asks and for what, the asking device's key fingerprint to compare, a failed
    /// answer, and the four answers stacked the card's width (``CmuxDialogSpec/Layout/stacked``): Allow Once first
    /// (Return), the two Always Allow choices under it, and Deny last as quiet red text (Escape).
    static func spec(_ request: SessionRequest, error: String?) -> CmuxDialogSpec {
        let title = String(format: request.scope == .full
            ? L.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
            : L.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName)
        let fields: [CmuxDialogField] = request.viewerKeyFingerprint.map {
            [.code(label: L.t("macScreen.approval.fingerprint", "Device key fingerprint"), text: fingerprintLines($0))]
        } ?? []
        func button(_ choice: MacScreenApprovalChoice, _ role: CmuxDialogButton.Role) -> CmuxDialogButton {
            CmuxDialogButton(id: choice.rawValue, title: choice.title, role: role)
        }
        return CmuxDialogSpec(
            title: title,
            lines: [String(format: L.t("macScreen.approval.scope", "Asks for %@."), request.scope.title)],
            fields: fields,
            buttons: [button(.once, .default), button(.alwaysView, .normal), button(.alwaysFull, .normal), button(.deny, .cancel)],
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
