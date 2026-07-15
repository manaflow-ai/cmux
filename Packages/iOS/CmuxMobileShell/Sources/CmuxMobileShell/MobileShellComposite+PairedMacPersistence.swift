import CMUXMobileCore
import Foundation
import os

private let pairedMacPersistenceLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobilePairedMacPersistence"
)

enum PairedMacInstanceTagUpdate {
    case preserve
    /// A no-tag fresh attach may persist while the row is still unclaimed, but
    /// cannot mutate routes owned by an authenticated tagged instance.
    case preserveOnlyIfUnclaimed
    case replace(String?)
}

@MainActor
extension MobileShellComposite {
    /// Persist a connection only with authority proven by authenticated status.
    /// Returns false when a no-tag fresh attach finds an existing tagged owner.
    @discardableResult
    func persistPairedMacFromTicket(
        _ ticket: CmxAttachTicket,
        instanceTagUpdate: PairedMacInstanceTagUpdate = .preserve,
        displayNameOverride: String? = nil,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        guard let pairedMacStore,
              !ticket.macDeviceID.isEmpty,
              ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return true }
        let stackUserID = identityProvider?.currentUserID
        let scope = await currentScopeSnapshot(userID: stackUserID)
        let ticketDisplayName = displayNameOverride ?? ticket.macDisplayName
        var accepted = true
        await performSerializedPairedMacWrite(ifStillCurrent: ifStillCurrent) { [weak self] in
            guard let self else { return }
            if let scope, await !self.isScopeCurrent(scope) { return }
            let scopedMacs = (try? await pairedMacStore.loadAll(
                stackUserID: stackUserID, teamID: scope?.teamID
            )) ?? []
            let existing = scopedMacs.first { $0.macDeviceID == ticket.macDeviceID }
            let storedTag = existing?.instanceTag
            var displayName = ticketDisplayName ?? existing?.displayName
            if displayName == nil {
                let knownMacs = (try? await pairedMacStore.loadAll(
                    stackUserID: nil, teamID: scope?.teamID
                )) ?? []
                displayName = knownMacs.first {
                    $0.macDeviceID == ticket.macDeviceID
                }?.displayName
            }
            let instanceTag: String?
            let authorityIsUnchanged: Bool
            switch instanceTagUpdate {
            case .preserve:
                instanceTag = storedTag
                authorityIsUnchanged = true
            case .preserveOnlyIfUnclaimed:
                instanceTag = nil
                authorityIsUnchanged = true
            case .replace(let reportedTag):
                instanceTag = reportedTag
                authorityIsUnchanged = reportedTag == storedTag
            }
            let storedRoutes = existing?.routes ?? []
            let routes = authorityIsUnchanged
                && ticket.routes.count == 1 && !storedRoutes.isEmpty
                ? Self.mergedReconnectRoutes(
                    ticketRoutes: ticket.routes, storedRoutes: storedRoutes
                )
                : ticket.routes
            do {
                if case .preserveOnlyIfUnclaimed = instanceTagUpdate {
                    accepted = try await pairedMacStore.upsertRoutesIfAuthorized(
                        macDeviceID: ticket.macDeviceID,
                        displayName: displayName,
                        routes: routes,
                        condition: .unclaimed,
                        markActive: true,
                        stackUserID: stackUserID,
                        teamID: scope?.teamID,
                        now: Date()
                    )
                    guard accepted else { return }
                } else {
                    try await pairedMacStore.upsert(
                        macDeviceID: ticket.macDeviceID,
                        displayName: displayName,
                        routes: routes,
                        instanceTag: instanceTag,
                        markActive: true,
                        stackUserID: stackUserID,
                        teamID: scope?.teamID,
                        now: Date()
                    )
                }
                await self.clearForgottenMacDeviceID(ticket.macDeviceID, scope: scope)
                self.hasKnownPairedMac = true
            } catch {
                pairedMacPersistenceLog.error(
                    "paired mac upsert failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return accepted
    }
}
