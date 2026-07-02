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

    /// Resolve one scope field (`workspaceID`/`terminalID`), keeping the scanned QR scope
    /// authoritative. A non-empty scanned value always wins, so a redeemed reply can only
    /// fill a field the scan left empty (the compact `v=3` grammar always scans empty scope)
    /// and can never retarget the ticket to a *different* non-empty scope than the QR the
    /// user actually scanned. Whitespace-only values count as empty.
    ///
    /// Kept as an instance method — not `static`, not a file-scope free func — so the pure
    /// helper stays scoped to its owning type without tripping either the package-convention
    /// free-function lint or the static-as-namespace policy.
    private func scopeFieldPreferringScanned(scanned: String?, redeemed: String?) -> String? {
        let scannedIsEmpty = scanned?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if !scannedIsEmpty {
            return scanned
        }
        let redeemedIsEmpty = redeemed?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return redeemedIsEmpty ? scanned : redeemed
    }

    /// Merge a freshly `redeemed` ticket over the `scanned` QR ticket, then stamp the
    /// resolved `ticketRef`. Routes stay the scanned set (the redeem reply omits them).
    ///
    /// Scope (`workspaceID`/`terminalID`) is constrained to the scanned QR: a non-empty
    /// scanned value is authoritative and the redeemed value only fills a scanned gap, so
    /// a partial or mismatched redeem response can neither widen the ticket with empty
    /// scope nor retarget it to a different workspace/terminal than was scanned. Non-scope
    /// fields prefer the redeemed value and fall back to the scan.
    func redeemedTicket(
        _ redeemed: CmxAttachTicket,
        ticketRef: String,
        constrainedTo scanned: CmxAttachTicket
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            version: redeemed.version,
            workspaceID: scopeFieldPreferringScanned(
                scanned: scanned.workspaceID, redeemed: redeemed.workspaceID) ?? scanned.workspaceID,
            terminalID: scopeFieldPreferringScanned(
                scanned: scanned.terminalID, redeemed: redeemed.terminalID),
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
