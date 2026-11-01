import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
public import CmuxNextMobile
public import Foundation
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

    /// Loads the list of the signed-in user; a sign-out forgets that user's phones. The list is
    /// read off the main actor (its seal is a Keychain item), after every save already queued;
    /// until it is in, no phone is trusted and no pairing is decided (each needs `paired`).
    /// The store's one list file for `directory`, wired to the last quit's record and watched by the quit deadline.
    func configurePairedFile(_ directory: URL) {
        let record = pairedQuitRecord
        let file = pairedStore.configure(directory: directory, lastQuitCutOff: { record?.lastQuitCutOffPairedPhones() ?? false },
                                         cutOffSettled: { record?.pairedCutOffSettled() })
        guard pairedFile !== file else { return }
        pairedFile = file
        pairedQuitWatch.watch(file)
    }

    func loadPaired(signedOut: Bool) {
        if let directory = dependencies?.stateDirectory { configurePairedFile(directory) }
        if pairedStore.current?.userID != account?.userID { resetPrompts() }
        pairedStore.select(userID: account?.userID)
        paired = pairedStore.current
        // task-owner: one queued read; generation checks discard a superseded account
        Task { [pairedStore] in await pairedStore.reload() }
        if approverSync == nil, let environment = dependencies?.acpmuxEnvironment {
            approverSync = makeApproverSync(environment)
        }
        pushPaired()
    }

    /// Settings > Mobile: forget a phone. Its live links end now, its next link asks
    /// again, and its Face ID approvals stop counting at once.
    public func revokePhone(id: String) {
        prompts.forget(id: id)
        showPairDialog()
        if prompts.pending.isEmpty { quietAttention() }
        pairedStore.forget(id: id)
        let supervisor = supervisor
        // task-owner: one hop to the supervisor actor; dropping a phone with no link is a no-op
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
        // A request hostd sent before connections were turned off asks nothing.
        guard allowed, let list = pairedStore.current else { return }
        switch list.decision(for: request) {
        case .trusted, .denied:
            // hostd may hold an older list: send the current one again.
            pushPaired()
            return
        case .ask:
            break
        }
        // Test-only (DEBUG builds; nil in Release): a tagged rig instance's seeded phone
        // pairs without the person-only prompt (IPhonePairingSeed).
        if let seed = dependencies?.pairingSeed, seed.trusts(request), pairedStore.current?.userID == account?.userID {
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) paired from the test seed")
            savePaired { $0.approve(request, at: Date()) }
            return
        }
        // This Mac's pairing code: the live pre-approval, minted for this device id, allows the phone
        // once, in place of the person's Allow. hostd served this phone only because the service
        // stamped its dial with the signed-in user, and the list is that user's.
        if !removed, let trusted = pairedStore.current,
           Self.redeems(request, tokens: &pairTokens, macDeviceID: state.deviceID, pairedUserID: trusted.userID,
                        accountUserID: account?.userID) {
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) paired from this Mac's pairing code")
            var withoutToken = request
            withoutToken.pairToken = nil
            let allowed = withoutToken
            savePaired { $0.approve(allowed, at: Date()) }
            // An earlier request from this phone (before it scanned) is answered: its prompt closes,
            // so a stale Allow cannot overwrite the keys just approved.
            prompts.forget(id: request.phoneDeviceID)
            if prompts.pending.isEmpty { quietAttention() }
            showPairDialog()
            return
        }
        // A waiting request never keeps a token.
        var request = request
        request.pairToken = nil
        let outcome = prompts.receive(request, at: Date())
        Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) asks to pair: \(String(describing: outcome), privacy: .public)")
        if outcome == .ask { announce(request) }
        showPairDialog()
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

    /// A waiting prompt shows when a cmux window becomes main or the app comes forward
    /// (one pair of observers for the service's life; a pass with nothing waiting does nothing).
    private func watchForPairWindow() {
        guard pairWindowWatch.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSApplication.didBecomeActiveNotification] {
            pairWindowWatch.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // task-owner: one hop to the main actor per window or app activation; ends at once
                Task { @MainActor [weak self] in self?.showPairDialog() }
            })
        }
    }

    private func decide(_ request: MobileHostPairRequest, allow: Bool) {
        prompts.answer(id: request.phoneDeviceID, allowed: allow, at: Date())
        if prompts.pending.isEmpty { quietAttention() }
        Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) \(allow ? "allowed" : "denied", privacy: .public)")
        savePaired { list in
            if allow { list.approve(request, at: Date()) } else { list.deny(request) }
        }
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

    /// Whether `request` carries this Mac's live pre-approval, for the paired list of the signed-in
    /// user; the token is burnt when it does. Never true for another user's list or no account.
    static func redeems(_ request: MobileHostPairRequest, tokens: inout MobileHostPairTokens, macDeviceID: String?,
                        pairedUserID: String, accountUserID: String?, now: Date = Date()) -> Bool {
        guard let token = request.pairToken, let accountUserID, pairedUserID == accountUserID else { return false }
        return tokens.redeem(token, macDeviceID: macDeviceID, now: now)
    }

    /// This Mac's pairing code for cmux on iPhone: its device id and team, its name, the live
    /// pre-approval (a new one a minute before the shown one expires) and its identity key's hash.
    /// Nil until hostd is online for the signed-in account with iPhone connections on, and nil
    /// once this Mac was removed from the account.
    public func pairInvite(macName: String, now: Date = Date()) -> MobileHostPairInvite? {
        // A Mac removed from the account mints nothing, even while hostd still reports online.
        guard allowed, !removed, account != nil, state.phase == .online, let device = state.deviceID,
              let team = state.teamID, let key = macPublicKey else { return nil }
        let token = pairTokens.current(macDeviceID: device, now: now)
        return MobileHostPairInvite(macDeviceID: device, teamID: team, macName: macName, token: token.token,
                                    macPublicKey: key, expiresAt: token.expiresAt)
    }

    /// The account changed: its waiting requests, quiet period, blocked count and pairing code go with it.
    func resetPrompts() {
        pairTokens.revoke()
        prompts = MobileHostPairPrompts()
        quietAttention()
        showPairDialog()
    }

    /// Every save (a phone added, removed or re-keyed) makes the list it replaces stop counting
    /// (``MobileHostPairedDevicesFile/save(_:)``).
    private func savePaired(_ edit: @escaping @Sendable (inout MobileHostPairedDevices) -> Void) {
        guard let user = account?.userID else { return }
        let logger = Self.logger
        // Queued in this turn, so a removal right after it (Settings > Mobile) still wins.
        pairedStore.submit(for: user, generation: pairedStore.generation, edit) { error in
            if let error { logger.error("paired phones not saved: \(String(describing: error), privacy: .public)") }
        }
    }

    /// The approver sync, which also hands hostd each phone's own acpmux credential.
    func makeApproverSync(_ environment: AcpmuxEnvironment) -> MobileHostApproverSync {
        let sync = MobileHostApproverSync(environment: environment)
        let supervisor = supervisor
        sync.phoneCredentialsChanged = { credentials in
            // task-owner: one hop to the supervisor actor; setPhoneCredentials replaces the whole set
            Task { await supervisor.setPhoneCredentials(credentials) }
        }
        return sync
    }

    /// hostd's `devices` line and acpmux's approvers follow the list.
    func pushPaired() {
        let list = pairedStore.current ?? MobileHostPairedDevices(userID: "")
        // At once: the next hostd start or restart gets this list, never an older one.
        supervisor.setNewestDevices(list)
        guard let directory = dependencies?.stateDirectory,
              let macDevice = try? MobileHostDeviceIdentity(directory: directory).deviceID() else { return }
        approverSync?.update(list.approversParams(macDevice: macDevice))
        pushListedPhones()
    }

    /// The paired phones the account lists get their own acpmux credential (their Full-access
    /// setting); every other phone's record is revoked. Until the account's list is read (or
    /// connections are off), none gets one and none is revoked for being unlisted.
    func pushListedPhones() {
        let paired = pairedStore.current ?? MobileHostPairedDevices(userID: "")
        approverSync?.updatePhones(paired: Set(paired.hostdDevices.map(\.id)),
                                   listed: phonesKnown ? paired.listed(in: knownPhones) : nil)
    }
}
