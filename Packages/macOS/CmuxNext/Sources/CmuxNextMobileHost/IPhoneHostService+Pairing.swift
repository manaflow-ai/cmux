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
///   Settings > Mobile removes one with ``revokePhone(id:)``; the person's own sign-out
///   of this Mac forgets them all (``signOutStarted()``), a session that ends by itself does not.
extension IPhoneHostService {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone.pairing")
    /// The pairing dialog: only the user answers it (a phone it admits reaches the
    /// daemon and acpmux), so `debug.dialog` automation may not press it.
    public static let pairDialogIdentifier = "cmux.dialog.iphonePair"
    static let allowButton = "allow"
    static let denyButton = "deny"

    /// Loads the list of the signed-in user (none while signed out; the stored list stays). The list is
    /// read off the main actor (its seal is a Keychain item), after every save already queued;
    /// until it is in, no phone is trusted and no pairing is decided (each needs `paired`).
    /// The store's one list file for `directory`, wired to the last quit's record and watched by the quit deadline.
    func configurePairedFile(_ directory: URL) {
        let record = pairedQuitRecord
        let file = pairedStore.configure(directory: directory, sealName: dependencies?.pairingSealName, lastQuitCutOff: { record?.lastQuitCutOffPairedPhones() ?? false },
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

    /// The person signs out of this Mac (``CloudService/willSignOut``, while the account is still
    /// selected): its phones are forgotten, so each asks again after a sign-in. A session that ends
    /// by itself (a refused refresh token, a Keychain that would not hand back the tokens) keeps
    /// them: signing in again must not ask the person to allow every phone again.
    public func signOutStarted() {
        pairedStore.forgetForSignOut()
        // A prompt still open would allow its phone after the forget.
        resetPrompts()
        paired = nil
        pushPaired()
    }

    /// Settings > Mobile: forget a phone. Its live links end now, its next link asks
    /// again, and its Face ID approvals stop counting at once.
    public func revokePhone(id: String) {
        prompts.forget(id: id)
        showPairDialog()
        if !loudRequestWaits { quietAttention() }
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
        case let .pairAnswer(id, identityKey, approvalKey, allow, by):
            answerFromPairedDevice(id: id, identityKey: identityKey, approvalKey: approvalKey, allow: allow, by: by)
        default:
            break
        }
    }

    private func ask(_ request: MobileHostPairRequest) {
        // A request hostd sent before connections were turned off asks nothing.
        guard allowed else { return }
        // Before the list is in nothing is decided; the request waits for it.
        guard let list = pairedStore.current else {
            heldPairRequests.hold(request)
            return
        }
        switch list.decision(for: request) {
        case .trusted, .denied:
            // hostd may hold an older list: send the current one again.
            pushPaired()
            return
        case .ask:
            break
        }
        // DEBUG tagged dev builds only (nil in Release and with CMUX_NEXT_IPHONE_APPROVE_FIRST=1): this
        // tag's own iPhone app of the signed-in user pairs as Allow would (IPhoneDevAutoApprove).
        if !removed, Self.devAutoApproves(request, devAutoApprove: dependencies?.devAutoApprove, pairedUserID: list.userID,
                                accountUserID: account?.userID) {
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) paired from the dev auto-approve")
            savePaired { $0.approve(request, at: Date()) }
            prompts.forget(id: request.phoneDeviceID)
            if !loudRequestWaits { quietAttention() }
            showPairDialog()
            return
        }
        // Test-only (DEBUG builds; nil in Release): a tagged rig instance's seeded phone
        // pairs without the person-only prompt (IPhonePairingSeed).
        if let seed = dependencies?.pairingSeed, seed.trusts(request), pairedStore.current?.userID == account?.userID {
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) paired from the test seed")
            savePaired { $0.approve(request, at: Date()) }
            return
        }
        // The person's own `mobile.autoApprovePhones` (off by default): a phone of the signed-in
        // user pairs as Allow would. hostd served this phone only because the service stamped its
        // dial with the signed-in user, and the list is that user's. Machines still ask, and another
        // build's dev iPhone app still waits quietly below: the quiet ask decides it, not the setting.
        if !removed, Self.autoApproves(request, on: dependencies?.autoApprovePhones() ?? false, macDevTag: dependencies?.macDevTag,
                                       pairedUserID: list.userID, accountUserID: account?.userID) {
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) paired by Approve Phone Requests Automatically")
            savePaired { $0.approve(request, at: Date()) }
            // An earlier request from this phone is answered: its prompt closes, so a stale Allow
            // cannot overwrite the keys just approved.
            prompts.forget(id: request.phoneDeviceID)
            if !loudRequestWaits { quietAttention() }
            showPairDialog()
            return
        }
        // Another build's dev iPhone app waits quietly, in places of its own (MobileHostPairPrompts.quietLimit).
        let outcome = prompts.receive(request, at: Date(), quietly: asksQuietly(request))
        Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) asks to pair: \(String(describing: outcome), privacy: .public)")
        if outcome == .ask { announce(request) }
        showPairDialog()
    }

    /// Settings > Mobile's Allow or Don't Allow on a waiting request (the person's own gesture,
    /// ``MobilePageProvider``). False when phone `id` has no waiting request.
    @discardableResult
    /// Another of the person's paired devices answered a waiting request (hostd `pair-requests`;
    /// hostd checked that the answering device is paired here, of this Mac's account, and named the
    /// request by its fingerprint). It counts as the person's own Allow or Don't Allow, so a probe
    /// phone of the same account pairs with no gesture on this Mac. Only a request still waiting
    /// here with the same keys is answered, and only while the answering device is still paired.
    /// `by` is this Mac's own device id when its owner answered with `cmux mobile pair-requests`
    /// on this Mac (hostd's owner-only link socket, peer uid checked): the same OS user as this
    /// app's Allow button.
    func answerFromPairedDevice(id: String, identityKey: String, approvalKey: String, allow: Bool, by: String) {
        let byThisMac = state.deviceID == by
        guard let request = prompts.request(id: id), request.identityKey == identityKey,
              request.approvalKey == approvalKey, by != id,
              byThisMac || pairedStore.current?.hostdDevices.contains(where: { $0.id == by }) == true
        else {
            Self.logger.info("phone \(id.prefix(8), privacy: .public) answer from \(by.prefix(8), privacy: .public) matched no waiting request")
            return
        }
        Self.logger.info("phone \(id.prefix(8), privacy: .public) answered from paired device \(by.prefix(8), privacy: .public)")
        decide(request, allow: allow)
    }

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
        guard pairDialog == nil, !prompts.isQuiet(at: Date()),
              let request = prompts.prompted.first else { return }
        // In the app only, never a floating window: a sheet on the frontmost cmux window. With
        // none on screen it waits (the banner, the Dock and Settings > Mobile still tell the
        // person) and shows when a cmux window next becomes main or the app comes forward.
        guard let scope = Self.pairScope(window: pairWindow?()) else {
            watchForPairWindow()
            return
        }
        let name = Self.displayName(request)
        let who = account?.email ?? account?.userID ?? ""
        var lines = [request.isMachine ? IPhoneHostStrings.machinePairBody(who) : IPhoneHostStrings.pairBody(who)]
        if let registered = request.registeredAt { lines.append(IPhoneHostStrings.deviceRegistered(registered)) }
        // A machine has no approval key: its identity key is the one it proves at every link.
        let key = request.isMachine ? request.identityKey : request.approvalKey
        lines.append(IPhoneHostStrings.pairKey(MobileHostPairedDevices.fingerprint(key)))
        let spec = CmuxDialogSpec(usesTransientMaterial: true,
            title: IPhoneHostStrings.pairTitle(name, key: request.shortFingerprint), lines: lines,
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
        if !loudRequestWaits { quietAttention() }
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

    /// Whether `mobile.autoApprovePhones` (`on`) pairs `request` without the prompt: a phone, never
    /// a machine, on the paired list of the signed-in user. Never true with the setting off, no
    /// account or another user's list, nor for a request the quiet ask holds on this Mac
    /// (`macDevTag`, ``IPhoneDevAutoApprove/asksQuietly(_:macDevTag:)``): another build's dev iPhone
    /// app waits quietly whether the setting is on or off, so the setting never pairs a dev phone
    /// with NIGHTLY, release or another tag's dev build.
    static func autoApproves(_ request: MobileHostPairRequest, on: Bool, macDevTag: String?, pairedUserID: String,
                             accountUserID: String?) -> Bool {
        guard on, !request.isMachine, let accountUserID, !accountUserID.isEmpty else { return false }
        guard !IPhoneDevAutoApprove.asksQuietly(request, macDevTag: macDevTag) || pairsWithoutBuildSpace(request, macDevTag: macDevTag)
        else { return false }
        return pairedUserID == accountUserID
    }

    /// The iPhone apps named `dev.cmux.mobile.<name>` that carry no cloud build space, so their Mac is NIGHTLY, RC or
    /// release (the space with none): the Production configuration (`prod`, project.yml), the shared Demo build (`demo`,
    /// demo-build.sh) and cmux Dev (`dev`, try.sh, which shows the person's real data). These names are reserved tags
    /// (CMUX_ATTACH_RESERVED_TAGS), so no tagged dev build has them. The quiet ask still holds them from the prompt, but the
    /// person's setting pairs them on a Mac with no dev tag, as before 2026-11-24.
    static let buildSpacelessPhones: Set<String> = ["prod", "demo", "dev"]

    static func pairsWithoutBuildSpace(_ request: MobileHostPairRequest, macDevTag: String?) -> Bool {
        guard macDevTag == nil, let tag = IPhoneDevAutoApprove.phoneTag(of: request) else { return false }
        return buildSpacelessPhones.contains(tag)
    }

    /// Whether `request` waits in Settings > Mobile only, without the prompt, banner or Dock bounce:
    /// another build's dev iPhone app (``IPhoneDevAutoApprove/asksQuietly(_:macDevTag:)``).
    func asksQuietly(_ request: MobileHostPairRequest) -> Bool {
        IPhoneDevAutoApprove.asksQuietly(request, macDevTag: dependencies?.macDevTag)
    }

    /// A waiting request that the prompt, banner and Dock bounce are for.
    var loudRequestWaits: Bool { !prompts.prompted.isEmpty }

    /// Whether the dev auto-approve pairs `request` without the prompt: a tagged dev build's
    /// (`devAutoApprove`, nil otherwise), for a phone of this tag's iPhone app, on the paired list of
    /// the signed-in user. Never true for a machine, another tag, no account or another user's list.
    static func devAutoApproves(_ request: MobileHostPairRequest, devAutoApprove: IPhoneDevAutoApprove?,
                                pairedUserID: String, accountUserID: String?) -> Bool {
        guard let devAutoApprove, let accountUserID, !accountUserID.isEmpty, pairedUserID == accountUserID else { return false }
        return devAutoApprove.matches(request)
    }

    /// Idle sleep is held off only while a phone this account allowed can reach this Mac: phone
    /// access is on by default, so a Mac with no paired phone sleeps as it would without cmux.
    func updateKeepAwake() {
        setKeepAwake(allowed && account != nil && !removed && !hostIdle && !(paired?.hostdDevices.isEmpty ?? true))
    }

    /// A start that ended without serving: the Mac may sleep until the next start (``hostIdle``).
    func idleHost() {
        hostIdle = true
        setKeepAwake(false)
    }

    /// `mobile.autoApprovePhones` turned on: the phones already waiting pair now, as a new request would
    /// (another build's dev iPhone app keeps waiting quietly, ``autoApproves(_:on:macDevTag:pairedUserID:accountUserID:)``).
    func autoApproveWaiting() {
        guard dependencies?.autoApprovePhones() ?? false else { return }
        for request in prompts.pending where !request.isMachine { ask(request) }
    }

    /// The paired list is in: each request that came before it is answered now.
    func answerHeldPairRequests() {
        guard pairedStore.current != nil, !heldPairRequests.isEmpty else { return }
        for request in heldPairRequests.release() { ask(request) }
    }

    /// The account changed: its waiting requests, quiet period and blocked count go with it.
    func resetPrompts() {
        heldPairRequests = MobileHostHeldPairRequests()
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
