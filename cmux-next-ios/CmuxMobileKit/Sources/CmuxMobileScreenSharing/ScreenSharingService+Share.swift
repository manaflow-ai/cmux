#if os(iOS)
public import CmuxDeviceHub
import CmuxMobileLinkFFI
public import Foundation

/// Share <Mac> from the iPhone (cmuxterm-hq#18912, cut 1). Leo, 2026-11-22: "well im not at the
/// computer right now unless screen sharing between ios and mac works then i can click". The design:
/// "Share works from your computer with zero actions on that machine: no app open there, no switch,
/// no approval".
///
/// A Mac that isn't shared offers "Share <Mac>". The tap is the person's yes: Rust builds the
/// approval (`cmux.share-approval.v1`, `share_approval_draft`), this phone signs its canonical bytes
/// with the key the device hub knows it by (the Secure Enclave call, the one step that stays in
/// Swift), Rust checks that signature against the phone's own hub key and answers the JSON the Mac
/// admits (`share_approval_signed`), and the carrier takes it to the Mac. When the list shows the
/// Mac sharing, the phone connects as a row tap would.
///
/// The carrier is cut 2's path (``ScreenSharingService/shareCarrier``). Until cut 2 fills it, the
/// tap signs nothing and says sharing from the iPhone isn't available yet.
public typealias ShareCarrier = @MainActor (_ approval: String, _ target: HubDevice, _ hub: DeviceHub) async throws -> Void

/// Why a Share tap did not get the Mac sharing, as an alert over the list.
public struct ScreenSharingShareProblem: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let hostName: String
    public let message: String
}

extension ScreenSharingService {
    /// The person tapped Share for `mac`: the only path that signs a share approval.
    public func share(_ mac: HubDevice, scope: SessionScope? = nil) {
        let scope = scope ?? preferences.defaultScope
        alert = nil
        shareProblem = nil
        guard let hub else { return }
        guard let carrier = shareCarrier else {
            shareProblem = ScreenSharingShareProblem(
                hostName: mac.name,
                message: String(localized: "Sharing a Mac from this iPhone isn't available yet. Turn on Share This Mac in the Mac's Settings › Devices."))
            return
        }
        endShare()
        sharing = PendingSelection(hostID: mac.id, hostName: mac.name, scope: scope)
        let identity = hub.identity
        let ask = ShareAsk(targetId: mac.id, targetName: mac.name, askerId: identity.id,
                           askerName: hub.thisDevice?.name ?? hub.deviceName,
                           account: hub.me?.userId ?? configuration.accountID ?? "")
        let sign = signApproval
        let deadline = shareDeadline
        // task-owner: one Share tap: sign, carry, then wait for the list to show the Mac sharing until
        // the deadline; a new tap, a connect or stop() cancels it (endShare)
        shareTask = Task { [weak self] in
            do {
                let draft = try shareApprovalDraft(ask: ask)
                let canonical = draft.canonical
                let signature = try await Task.detached { try sign(identity, canonical) }.value
                let approval = try shareApprovalSigned(draft: draft, signature: signature, signingKey: identity.signingKey)
                try Task.checkCancellation()
                try await carrier(approval, mac, hub)
                try await Task.sleep(for: deadline)
                self?.shareFailed(mac.id, String(localized: "\(mac.name) didn't turn on sharing. Check that cmux is open on it and signed in to your account."))
            } catch is CancellationError {
            } catch {
                self?.shareFailed(mac.id, Self.shareMessage(error))
            }
        }
    }

    /// An alert's Share for the listed Mac `id` (a Mac gone from the list since does nothing).
    func share(_ id: String, scope: SessionScope) {
        guard let mac = macs.first(where: { $0.id == id }) else { return }
        share(mac, scope: scope)
    }

    /// The list was read while a Share tap waits: the Mac sharing now connects; one that went
    /// offline or blocks this phone says why; one still not shared keeps waiting.
    func shareListed(_ listed: [HubDevice]) {
        guard let pending = sharing, let mac = listed.first(where: { $0.id == pending.hostID }) else { return }
        switch unavailability(of: mac) {
        case nil:
            endShare()
            connect(to: mac, scope: pending.scope)
        case .notShared?:
            return
        case let refusal?:
            endShare()
            alert = ScreenSharingMacAlert(hostID: mac.id, hostName: mac.name, refusal: refusal, requested: pending.scope)
        }
    }

    func endShare() {
        shareTask?.cancel()
        shareTask = nil
        sharing = nil
    }

    private func shareFailed(_ id: String, _ message: String) {
        guard let pending = sharing, pending.hostID == id else { return }
        sharing = nil
        shareTask = nil
        shareProblem = ScreenSharingShareProblem(hostName: pending.hostName, message: message)
    }

    nonisolated static func shareMessage(_ error: any Error) -> String {
        if case let CmuxMobileError.Refused(_, message) = error { return message }
        return error.localizedDescription
    }
}
#endif
