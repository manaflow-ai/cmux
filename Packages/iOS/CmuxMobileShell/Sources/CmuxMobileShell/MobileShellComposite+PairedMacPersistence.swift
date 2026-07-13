import CMUXMobileCore
import CmuxMobilePairedMac
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
        clearsForgottenMac: Bool = true,
        reconnectSourceMacDeviceID: String? = nil,
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
            guard ifStillCurrent?() ?? true else { return }
            if let scope, await !self.isScopeCurrent(scope) { return }
            let scopedMacs = (try? await pairedMacStore.loadAll(
                stackUserID: stackUserID, teamID: scope?.teamID
            )) ?? []
            let matchingMacs = scopedMacs.filter { $0.macDeviceID == ticket.macDeviceID }
            let existing = matchingMacs.first {
                $0.stackUserID == stackUserID && $0.teamID == scope?.teamID
            }
            let displayFallbackMac = existing
                ?? matchingMacs.first { $0.stackUserID == stackUserID }
                ?? matchingMacs.first
            let storedTag = existing?.instanceTag
            var displayName = ticketDisplayName ?? displayFallbackMac?.displayName
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
            let storedRoutes = displayFallbackMac?.routes ?? []
            let previousActiveMac = try? await pairedMacStore.activeMac(
                stackUserID: stackUserID,
                teamID: scope?.teamID
            )
            guard ifStillCurrent?() ?? true else {
                await self.removePersistedMacIfForgotten(
                    ticket.macDeviceID,
                    scope: scope,
                    store: pairedMacStore
                )
                return
            }
            if let scope, await !self.isScopeCurrent(scope) { return }
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
                guard ifStillCurrent?() ?? true else {
                    await self.rollbackStaleReconnectPersistenceIfNeeded(
                        persistedMacDeviceID: ticket.macDeviceID,
                        reconnectSourceMacDeviceID: reconnectSourceMacDeviceID,
                        previousPersistedMac: existing,
                        previousActiveMac: previousActiveMac,
                        scope: scope,
                        store: pairedMacStore
                    )
                    return
                }
                if let scope, await !self.isScopeCurrent(scope) { return }
                if clearsForgottenMac {
                    await self.clearForgottenMacDeviceID(ticket.macDeviceID, scope: scope)
                    guard ifStillCurrent?() ?? true else { return }
                }
                self.hasKnownPairedMac = true
            } catch {
                pairedMacPersistenceLog.error(
                    "paired mac upsert failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return accepted
    }

    func rollbackStaleReconnectPersistenceIfNeeded(
        persistedMacDeviceID: String,
        reconnectSourceMacDeviceID: String?,
        previousPersistedMac: MobilePairedMac?,
        previousActiveMac: MobilePairedMac?,
        scope: MobileShellScopeSnapshot?,
        store: any MobilePairedMacStoring
    ) async {
        guard let scope else { return }
        if await isForgottenMacDeviceID(persistedMacDeviceID, scope: scope) {
            await removePersistedMacIfForgotten(
                persistedMacDeviceID,
                scope: scope,
                store: store
            )
            return
        }
        guard let reconnectSourceMacDeviceID,
              reconnectSourceMacDeviceID != persistedMacDeviceID,
              await isForgottenMacDeviceID(reconnectSourceMacDeviceID, scope: scope) else {
            return
        }
        do {
            if let previousPersistedMac {
                try await store.upsert(
                    macDeviceID: previousPersistedMac.macDeviceID,
                    displayName: previousPersistedMac.displayName,
                    routes: previousPersistedMac.routes,
                    instanceTag: previousPersistedMac.instanceTag,
                    markActive: previousPersistedMac.isActive,
                    stackUserID: previousPersistedMac.stackUserID,
                    teamID: previousPersistedMac.teamID,
                    now: previousPersistedMac.lastSeenAt
                )
            } else {
                try await store.remove(
                    macDeviceID: persistedMacDeviceID,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            }
            if let previousActiveMac,
               previousActiveMac.macDeviceID != persistedMacDeviceID,
               !(await isForgottenMacDeviceID(previousActiveMac.macDeviceID, scope: scope)) {
                try await store.setActive(
                    macDeviceID: previousActiveMac.macDeviceID,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            }
        } catch {
            pairedMacPersistenceLog.error(
                "stale reconnect persistence rollback failed mac=\(persistedMacDeviceID, privacy: .private) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    func removePersistedMacIfForgotten(
        _ macDeviceID: String,
        scope: MobileShellScopeSnapshot?,
        store: any MobilePairedMacStoring
    ) async {
        guard let scope,
              await isForgottenMacDeviceID(macDeviceID, scope: scope) else { return }
        do {
            try await store.remove(
                macDeviceID: macDeviceID,
                stackUserID: scope.userID,
                teamID: scope.teamID
            )
        } catch {
            pairedMacPersistenceLog.error(
                "stale paired mac cleanup failed mac=\(macDeviceID, privacy: .private) error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}
