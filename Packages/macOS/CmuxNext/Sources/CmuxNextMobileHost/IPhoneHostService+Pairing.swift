import AppKit
import CmuxNextDesign
import CmuxNextMobile
import Foundation
import os

/// Phone pairing (cnx-ios verify/phone-approvals.md, audit B2): a phone reaches
/// this Mac only after the user allowed it here, and its Face ID approvals count
/// in acpmux only while it stays paired.
///
/// - hostd asks (``CnxHostEvent/pairRequest(_:)``) when a phone proved keys this
///   Mac has not approved; the user answers "Allow “<phone>” to connect?" once.
/// - The list (``CnxPairedDevices``, a 0600 file per user) goes to hostd as its
///   `devices` line and, as approval keys, to acpmux (``CnxApproverSync``).
/// - A phone that signs out asks to be forgotten (``CnxHostEvent/unpaired(phoneDeviceID:)``);
///   Settings > Mobile removes one with ``revokePhone(id:)``; signing out of
///   this Mac forgets them all.
extension IPhoneHostService {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone.pairing")
    /// The pairing dialog: only the user answers it (a phone it admits reaches the
    /// daemon and acpmux), so `debug.dialog` automation may not press it.
    public static let pairDialogIdentifier = "cmux.dialog.iphonePair"
    static let allowButton = "allow"
    static let denyButton = "deny"

    private var pairedFile: CnxPairedDevicesFile? {
        dependencies.map { CnxPairedDevicesFile(directory: $0.stateDirectory) }
    }

    /// Loads the list of the signed-in user; a sign-out forgets that user's phones.
    func loadPaired(signedOut: Bool) {
        guard let file = pairedFile else { return }
        if signedOut, let previous = paired {
            try? file.save(CnxPairedDevices(userID: previous.userID))
        }
        if paired?.userID != account?.userID { resetPrompts() }
        paired = account.map { file.load(userID: $0.userID) }
        if approverSync == nil, let environment = dependencies?.acpmuxEnvironment {
            approverSync = CnxApproverSync(environment: environment)
        }
        pushPaired()
    }

    /// Settings > Mobile: forget a phone. Its live links end now, its next link asks
    /// again, and its Face ID approvals stop counting at once.
    public func revokePhone(id: String) {
        prompts.forget(id: id)
        showPairDialog()
        if prompts.pending.isEmpty { quietAttention() }
        guard var list = paired else { return }
        list.remove(id)
        savePaired(list)
        let supervisor = supervisor
        // task-owner: one hop to the supervisor actor; dropping a phone with no link is a no-op
        Task { await supervisor.drop(phoneDeviceIDs: [id]) }
    }

    func pairingEvent(_ event: CnxHostEvent) {
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

    private func ask(_ request: CnxPairRequest) {
        guard let list = paired else { return }
        switch list.decision(for: request) {
        case .trusted, .denied:
            // hostd may hold an older list: send the current one again.
            pushPaired()
            return
        case .ask:
            break
        }
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
        let name = Self.displayName(request)
        var lines = [IPhoneHostStrings.pairBody(account?.email ?? account?.userID ?? "")]
        if let registered = request.registeredAt { lines.append(IPhoneHostStrings.deviceRegistered(registered)) }
        lines.append(IPhoneHostStrings.pairKey(CnxPairedDevices.fingerprint(request.approvalKey)))
        let spec = CmuxDialogSpec(
            title: IPhoneHostStrings.pairTitle(name), lines: lines,
            buttons: [CmuxDialogButton(id: Self.denyButton, title: IPhoneHostStrings.pairDeny, role: .cancel),
                      CmuxDialogButton(id: Self.allowButton, title: IPhoneHostStrings.pairAllow, role: .default)],
            identifier: Self.pairDialogIdentifier)
        var dialogID = 0
        dialogID = CmuxDialogCenter.shared.present(spec, in: .app) { [weak self] answer in
            // A prompt this service closed (answered in Settings, replaced, signed out) decides nothing.
            guard let self, pairDialog?.id == dialogID else { return }
            pairDialog = nil
            // A dismissal (the app quit) decides nothing: the request stays in Settings.
            guard !answer.isDismissal else { return }
            decide(request, allow: answer.button == Self.allowButton)
        }
        pairDialog = (dialogID, request)
    }

    private func decide(_ request: CnxPairRequest, allow: Bool) {
        prompts.answer(id: request.phoneDeviceID, allowed: allow, at: Date())
        if prompts.pending.isEmpty { quietAttention() }
        Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) \(allow ? "allowed" : "denied", privacy: .public)")
        if var list = paired, list.userID == account?.userID {
            if allow { list.approve(request, at: Date()) } else { list.deny(request) }
            savePaired(list)
        }
        showPairDialog()
    }

    static func displayName(_ request: CnxPairRequest) -> String {
        request.name.isEmpty ? IPhoneHostStrings.unnamedPhone : request.name
    }

    /// A new request: a banner with Review (Settings > Mobile) and a Dock bounce while cmux is
    /// not in front. The banner only points the person here; it answers nothing.
    private func announce(_ request: CnxPairRequest) {
        var body = [account?.email ?? account?.userID ?? ""].filter { !$0.isEmpty }.map(IPhoneHostStrings.signedInAs)
        if let registered = request.registeredAt { body.append(IPhoneHostStrings.deviceRegistered(registered)) }
        pairNotices?.post(IPhoneHostStrings.noticeTitle(Self.displayName(request)), body.joined(separator: " · "))
        if attentionRequest == nil, let app = NSApp, !app.isActive, !WindowDrawPolicy.isAutomationLaunch(ProcessInfo.processInfo.environment) {
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
        prompts = CnxPairPrompts()
        quietAttention()
        showPairDialog()
    }

    private func savePaired(_ list: CnxPairedDevices) {
        paired = list
        do {
            try pairedFile?.save(list)
        } catch {
            Self.logger.error("paired phones not saved: \(String(describing: error), privacy: .public)")
        }
        pushPaired()
    }

    /// hostd's `devices` line and acpmux's approvers follow the list.
    private func pushPaired() {
        let list = paired ?? CnxPairedDevices(userID: "")
        let supervisor = supervisor
        // task-owner: one hop to the supervisor actor; setDevices is idempotent
        Task { await supervisor.setDevices(list) }
        guard let directory = dependencies?.stateDirectory,
              let macDevice = try? CnxDeviceIdentity(directory: directory).deviceID() else { return }
        approverSync?.update(list.approversParams(macDevice: macDevice))
    }
}
