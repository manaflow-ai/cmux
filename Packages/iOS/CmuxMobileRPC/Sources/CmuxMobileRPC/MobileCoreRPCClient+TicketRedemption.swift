import CMUXMobileCore
import Foundation

extension MobileCoreRPCClient {
    /// The pending ticket's reference when it still needs Stack-auth redemption:
    /// a non-empty `ticketRef` with no resolved `authToken` yet. `nil` once the
    /// ticket carries its bearer token or has no reference to redeem.
    func ticketReferenceRequiringRedemption(in ticket: CmxAttachTicket) -> String? {
        guard let ticketRef = ticket.ticketRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ticketRef.isEmpty,
              ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return nil
        }
        return ticketRef
    }

    /// Merge a freshly `redeemed` ticket over the `scanned` QR ticket, preferring
    /// redeemed fields and filling gaps from the scan, then stamping the resolved
    /// `ticketRef`. Routes stay the scanned set (the redeem reply omits them).
    ///
    /// Empty or whitespace-only `workspaceID`/`terminalID` in the reply are treated
    /// as gaps and fall back to the scanned scope, so a partial redeem response can
    /// never widen the ticket past the workspace/terminal the QR was scoped to.
    func redeemedTicket(
        _ redeemed: CmxAttachTicket,
        ticketRef: String,
        constrainedTo scanned: CmxAttachTicket
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            version: redeemed.version,
            workspaceID: redeemed.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? scanned.workspaceID : redeemed.workspaceID,
            terminalID: redeemed.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? redeemed.terminalID : scanned.terminalID,
            macDeviceID: redeemed.macDeviceID.isEmpty ? scanned.macDeviceID : redeemed.macDeviceID,
            macDisplayName: redeemed.macDisplayName ?? scanned.macDisplayName,
            macUserEmail: redeemed.macUserEmail ?? scanned.macUserEmail,
            macUserID: redeemed.macUserID ?? scanned.macUserID,
            macPairingCompatibilityVersion: redeemed.macPairingCompatibilityVersion
                ?? scanned.macPairingCompatibilityVersion,
            macAppVersion: redeemed.macAppVersion ?? scanned.macAppVersion,
            macAppBuild: redeemed.macAppBuild ?? scanned.macAppBuild,
            routes: scanned.routes,
            expiresAt: redeemed.expiresAt,
            ticketRef: ticketRef,
            authToken: redeemed.authToken
        )
    }
}
