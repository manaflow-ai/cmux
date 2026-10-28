import AppKit
import CmuxNextDesign
import CmuxNextMobile
import CmuxNextWakeups
import Foundation
import os

/// Phone pairing (cmux-next-ios verify/phone-approvals.md, audit B2): a phone reaches
/// this Mac only after the user allowed it here, and its Face ID approvals count
/// in acpmux only while it stays paired.
///
/// - hostd asks (``MobileHostEvent/pairRequest(_:)``) when a phone proved keys this
///   Mac has not approved; the user answers "Allow “<phone>” to connect?" once.
/// - The list (``MobileHostPairedDevices``, a 0600 file per user) goes to hostd as its
///   `devices` line and, as approval keys, to acpmux (``MobileHostApproverSync``).
/// - A phone that signs out asks to be forgotten (``MobileHostEvent/unpaired(phoneDeviceID:)``);
///   Settings > Mobile removes one with ``revokePhone(id:)``; signing out of
///   this Mac forgets them all.
extension IPhoneHostService {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone.pairing")
    /// The pairing dialog: only the user answers it (a phone it admits reaches the
    /// daemon and acpmux), so `debug.dialog` automation may not press it.
    public static let pairDialogIdentifier = "cmux.dialog.iphonePair"
    static let allowButton = "allow"
    static let denyButton = "deny"

    /// The phones the signed-in user allowed on this Mac. Settings > Mobile marks them; Remove (or
    /// ``revokePhone(id:)``) forgets one.
    var paired: MobileHostPairedDevices? {
        get { pairing.paired }
        set { pairing.paired = newValue }
    }

    /// Pairing requests waiting for the person, and the anti-flood state (Settings > Mobile lists them).
    var prompts: MobileHostPairPrompts {
        get { pairing.prompts }
        set { pairing.prompts = newValue }
    }

    private var pairedFile: MobileHostPairedDevicesFile? {
        dependencies.map { MobileHostPairedDevicesFile(directory: $0.stateDirectory) }
    }

    /// Loads the list of the signed-in user; a sign-out forgets that user's phones.
    func loadPaired(signedOut: Bool) {
        guard let file = pairedFile else { return }
        if signedOut, let previous = paired {
            try? file.save(MobileHostPairedDevices(userID: previous.userID))
        }
        if paired?.userID != account?.userID { resetPrompts() }
        paired = account.map { file.load(userID: $0.userID) }
        ensureApproverSync()
        pushPaired()
    }

    /// Settings > Mobile: forget a phone. Its live links end now, its next link asks
    /// again, and its Face ID approvals stop counting at once.
    public func revokePhone(id: String) {
        let listChanged = pairing.revoke(id: id)
        showPairDialog()
        if prompts.pending.isEmpty { quietAttention() }
        guard listChanged else { return }
        savePaired()
        let supervisor = supervisor
        // task-owner: one hop to the supervisor actor; dropping a phone with no link is a no-op
        // main-hop-allow: main's FIFO starts it after the list push above, so the supervisor gets them in order
        Task { await supervisor.drop(phoneDeviceIDs: [id]) }
    }

    func pairingEvent(_ event: MobileHostEvent) {
        switch event {
        case .pairRequest(let request):
            ask(request)
        case .unpaired(let id):
            Self.logger.info("phone \(id.prefix(8), privacy: .public) signed out; forgetting it")
            revokePhone(id: id)
        default:
            break
        }
    }

    private func ask(_ request: MobileHostPairRequest) {
        // Test-only (DEBUG builds; nil in Release): a tagged rig instance's seeded phone
        // pairs without the person-only prompt (IPhonePairingSeed).
        let seed = dependencies?.pairingSeed
        let asked = pairing.ask(request, allowed: allowed, userID: account?.userID, at: Date()) { seed?.trusts($0) ?? false }
        switch asked {
        case .ignored:
            // A request hostd sent before connections were turned off asks nothing.
            return
        case .known:
            // hostd may hold an older list: send the current one again.
            pushPaired()
        case .seeded:
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) paired from the test seed")
            savePaired()
        case let .prompted(outcome):
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) asks to pair: \(String(describing: outcome), privacy: .public)")
            if outcome == .ask { announce(request) }
            showPairDialog()
        }
    }

    /// Settings > Mobile's Allow or Don't Allow on a waiting request (the person's own gesture,
    /// ``MobilePageProvider``). False when phone `id` has no waiting request.
    @discardableResult
    public func answerPairRequest(id: String, allow: Bool) -> Bool {
        guard let request = prompts.request(id: id) else { return false }
        decide(request, allow: allow)
        return true
    }

    /// The prompt shows the oldest waiting request, one at a time, unless a Don't Allow quiets
    /// them; a request answered in Settings (or replaced) closes its prompt.
    func showPairDialog() {
        if let open = pairDialog, prompts.request(id: open.request.phoneDeviceID) != open.request {
            pairDialog = nil
            CmuxDialogCenter.shared.dismiss(open.id)
        }
        guard pairDialog == nil, !prompts.isQuiet(at: Date()), let request = prompts.pending.first else { return }
        // In the app only, never a floating window: a sheet on the frontmost cmux window. With
        // none on screen it waits (the banner, the Dock and Settings > Mobile still tell the
        // person) and shows when a cmux window next becomes main or the app comes forward.
        guard let scope = Self.pairScope(window: pairWindow?()) else {
            watchForPairWindow()
            return
        }
        let name = Self.displayName(request)
        var lines = [IPhoneHostStrings.pairBody(account?.email ?? account?.userID ?? "")]
        if let registered = request.registeredAt { lines.append(IPhoneHostStrings.deviceRegistered(registered)) }
        lines.append(IPhoneHostStrings.pairKey(MobileHostPairedDevices.fingerprint(request.approvalKey)))
        let spec = CmuxDialogSpec(
            title: IPhoneHostStrings.pairTitle(name), lines: lines,
            buttons: [CmuxDialogButton(id: Self.denyButton, title: IPhoneHostStrings.pairDeny, role: .cancel),
                      CmuxDialogButton(id: Self.allowButton, title: IPhoneHostStrings.pairAllow, role: .default)],
            identifier: Self.pairDialogIdentifier)
        var dialogID = 0
        dialogID = CmuxDialogCenter.shared.present(spec, in: scope) { [weak self] answer in
            // A prompt this service closed (answered in Settings, replaced, signed out) decides nothing.
            guard let self, pairDialog?.id == dialogID else { return }
            pairDialog = nil
            // A dismissal (the app quit) decides nothing: the request stays in Settings.
            guard !answer.isDismissal else { return }
            decide(request, allow: answer.button == Self.allowButton)
        }
        // A dialog that ended at once (no place to show it) is not open.
        if CmuxDialogCenter.shared.record(dialogID) != nil { pairDialog = (dialogID, request) }
    }

    /// Where the prompt shows: a sheet on `window` when it is on screen; nil (wait) otherwise.
    static func pairScope(window: NSWindow?) -> CmuxDialogScope? {
        guard let window, window.isVisible, !window.isMiniaturized else { return nil }
        return .window(window)
    }

    /// A waiting prompt shows when a cmux window becomes main or the app comes forward (one pair of
    /// subscriptions on the app's notice fan-out for the service's life; a pass with nothing waiting does
    /// nothing). The sheet goes up one visible task after the notice, once AppKit finished the activation.
    private func watchForPairWindow() {
        guard pairWindowWatch.isEmpty, let appEvents, let mainWork = deadlines?.work else { return }
        let show: @MainActor () -> Void = { [weak self] in
            mainWork.post(.visible, owner: "IPhoneHost.pairWindow") { [weak self] in self?.showPairDialog() }
        }
        pairWindowWatch = [
            appEvents.subscribe(NSWindow.didBecomeMainNotification, owner: "IPhoneHost.pairWindow", show),
            appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "IPhoneHost.pairWindow", show),
        ]
    }

    private func decide(_ request: MobileHostPairRequest, allow: Bool) {
        let listChanged = pairing.decide(request, allow: allow, userID: account?.userID, at: Date())
        if prompts.pending.isEmpty { quietAttention() }
        Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) \(allow ? "allowed" : "denied", privacy: .public)")
        if listChanged { savePaired() }
        showPairDialog()
    }

    static func displayName(_ request: MobileHostPairRequest) -> String {
        request.name.isEmpty ? IPhoneHostStrings.unnamedPhone : request.name
    }

    /// A new request: a banner with Review (Settings > Mobile) and a Dock bounce while cmux is
    /// not in front. The banner only points the person here; it answers nothing.
    private func announce(_ request: MobileHostPairRequest) {
        var body = [account?.email ?? account?.userID ?? ""].filter { !$0.isEmpty }.map(IPhoneHostStrings.signedInAs)
        if let registered = request.registeredAt { body.append(IPhoneHostStrings.deviceRegistered(registered)) }
        pairNotices?.post(IPhoneHostStrings.noticeTitle(Self.displayName(request)), body.joined(separator: " · "))
        // The system ends a bounce once cmux comes to the front; a later request bounces again.
        if let app = NSApp, !app.isActive, !WindowDrawPolicy.isAutomationLaunch(ProcessInfo.processInfo.environment) {
            if let attentionRequest { app.cancelUserAttentionRequest(attentionRequest) }
            attentionRequest = app.requestUserAttention(.criticalRequest)
        }
    }

    /// Nothing waits any more: the banner and the Dock bounce go.
    func quietAttention() {
        pairNotices?.withdraw()
        if let attentionRequest { NSApp?.cancelUserAttentionRequest(attentionRequest) }
        attentionRequest = nil
    }

    /// The account changed: its waiting requests, quiet period and blocked count go with it.
    func resetPrompts() {
        prompts = MobileHostPairPrompts()
        quietAttention()
        showPairDialog()
    }

    /// Saves the current list, then pushes it to hostd and acpmux.
    private func savePaired() {
        guard let list = paired else { return }
        do {
            try pairedFile?.save(list)
        } catch {
            Self.logger.error("paired phones not saved: \(String(describing: error), privacy: .public)")
        }
        pushPaired()
    }

    /// hostd's `devices` line and acpmux's approvers follow the list.
    private func pushPaired() {
        let list = paired ?? MobileHostPairedDevices(userID: "")
        let supervisor = supervisor
        // task-owner: one hop to the supervisor actor; setDevices is idempotent
        // main-hop-allow: main's FIFO starts the pushes in call order, so an older list never lands after a newer one
        Task { await supervisor.setDevices(list) }
        guard let directory = dependencies?.stateDirectory,
              let macDevice = try? MobileHostDeviceIdentity(directory: directory).deviceID() else { return }
        approverSync?.update(list.approversParams(macDevice: macDevice))
    }
}
