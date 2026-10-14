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
        paired = account.map { file.load(userID: $0.userID) }
        if approverSync == nil, let environment = dependencies?.acpmuxEnvironment {
            approverSync = CnxApproverSync(environment: environment)
        }
        pushPaired()
    }

    /// Settings > Mobile: forget a phone. Its links stop at the next pairing check
    /// and its Face ID approvals stop counting at once.
    public func revokePhone(id: String) {
        guard var list = paired else { return }
        list.remove(id)
        savePaired(list)
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
        guard asking.insert(request.phoneDeviceID).inserted else { return }
        let name = request.name.isEmpty ? IPhoneHostStrings.unnamedPhone : request.name
        let spec = CmuxDialogSpec(
            title: IPhoneHostStrings.pairTitle(name),
            lines: [IPhoneHostStrings.pairBody(account?.email ?? account?.userID ?? ""),
                    IPhoneHostStrings.pairKey(CnxPairedDevice(id: request.phoneDeviceID, name: name,
                                                              identityKey: request.identityKey,
                                                              approvalKey: request.approvalKey,
                                                              pairedAt: Date()).fingerprint)],
            buttons: [CmuxDialogButton(id: Self.denyButton, title: IPhoneHostStrings.pairDeny, role: .cancel),
                      CmuxDialogButton(id: Self.allowButton, title: IPhoneHostStrings.pairAllow, role: .default)],
            identifier: "cmux.dialog.iphonePair")
        Self.logger.info("asking to pair phone \(request.phoneDeviceID.prefix(8), privacy: .public)")
        CmuxDialogCenter.shared.present(spec, in: .app) { [weak self] answer in
            guard let self else { return }
            asking.remove(request.phoneDeviceID)
            // A dismissal (the app quit, the dialog withdrawn) decides nothing:
            // the phone asks again on its next link.
            guard !answer.isDismissal, var list = paired, list.userID == account?.userID else { return }
            if answer.button == Self.allowButton {
                list.approve(request, at: Date())
            } else {
                list.deny(request)
            }
            Self.logger.info("phone \(request.phoneDeviceID.prefix(8), privacy: .public) \(answer.button, privacy: .public)")
            savePaired(list)
        }
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
