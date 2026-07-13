import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

@MainActor
extension MobileShellComposite {
    /// Enqueues one paired-Mac store mutation on the serialized write chain.
    ///
    /// All `markActive` writes execute strictly in submission order, with
    /// `ifStillCurrent` re-evaluated after every earlier write has landed.
    @discardableResult
    private func enqueueSerializedPairedMacWrite(
        ifStillCurrent: (() -> Bool)?,
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = pairedMacWriteChain
        let task = Task { @MainActor in
            await previous?.value
            if let ifStillCurrent, !ifStillCurrent() { return }
            await operation()
        }
        pairedMacWriteChain = task
        return task
    }

    /// Runs one paired-Mac store mutation on the serialized write chain.
    func performSerializedPairedMacWrite(
        ifStillCurrent: (() -> Bool)?,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let task = enqueueSerializedPairedMacWrite(
            ifStillCurrent: ifStillCurrent,
            operation
        )
        await task.value
    }

    @discardableResult
    func enqueueActivePairedMacWrite(
        macDeviceID: String,
        scope: MobileShellScopeSnapshot?,
        reloadAfterWrite: Bool
    ) -> Task<Void, Never>? {
        guard let pairedMacStore else { return nil }
        return enqueueSerializedPairedMacWrite(ifStillCurrent: nil) { [weak self, pairedMacStore] in
            guard let self else { return }
            if let scope {
                guard await self.isScopeCurrent(scope) else { return }
            }
            guard self.connectionState == .connected,
                  self.remoteClient != nil,
                  self.foregroundMacDeviceID == macDeviceID else { return }
            do {
                try await pairedMacStore.setActive(
                    macDeviceID: macDeviceID,
                    stackUserID: scope?.userID,
                    teamID: scope?.teamID
                )
                guard self.connectionState == .connected,
                      self.remoteClient != nil,
                      self.foregroundMacDeviceID == macDeviceID else { return }
                if reloadAfterWrite {
                    await self.loadPairedMacs()
                }
            } catch {
                mobileShellLog.error("paired mac store setActive failed mac=\(macDeviceID, privacy: .private) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Persists `ticket` as the active paired Mac on the serialized write chain.
    func persistPairedMacFromTicket(
        _ ticket: CmxAttachTicket,
        clearsForgottenMac: Bool = true,
        reconnectSourceMacDeviceID: String? = nil,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        guard let pairedMacStore else { return }
        guard !ticket.macDeviceID.isEmpty else { return }
        guard ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return }
        let stackUserID = identityProvider?.currentUserID
        let scope = await currentScopeSnapshot(userID: stackUserID)
        let ticketDisplayName = ticket.macDisplayName
        await performSerializedPairedMacWrite(ifStillCurrent: ifStillCurrent) { [weak self] in
            guard let self else { return }
            guard ifStillCurrent?() ?? true else { return }
            if let scope {
                guard await self.isScopeCurrent(scope) else { return }
            }
            var displayName = ticketDisplayName
            var storedRoutes: [CmxAttachRoute] = []
            let previousPersistedMac: MobilePairedMac?
            if displayName == nil {
                let knownMacs = (try? await pairedMacStore.loadAll(
                    stackUserID: nil,
                    teamID: scope?.teamID
                )) ?? []
                let matches = knownMacs.filter { $0.macDeviceID == ticket.macDeviceID }
                previousPersistedMac = matches.first { $0.stackUserID == stackUserID }
                    ?? matches.first
                displayName = previousPersistedMac?.displayName
                storedRoutes = previousPersistedMac?.routes ?? []
            } else {
                let scopedMacs = (try? await pairedMacStore.loadAll(
                    stackUserID: stackUserID,
                    teamID: scope?.teamID
                )) ?? []
                previousPersistedMac = scopedMacs.first {
                    $0.macDeviceID == ticket.macDeviceID
                }
                storedRoutes = previousPersistedMac?.routes ?? []
            }
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
            if let scope {
                guard await self.isScopeCurrent(scope) else { return }
            }
            let routesToPersist = ticket.routes.count == 1 && !storedRoutes.isEmpty
                ? Self.mergedReconnectRoutes(ticketRoutes: ticket.routes, storedRoutes: storedRoutes)
                : ticket.routes
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: ticket.macDeviceID,
                    displayName: displayName,
                    routes: routesToPersist,
                    markActive: true,
                    stackUserID: stackUserID,
                    teamID: scope?.teamID,
                    now: Date()
                )
                guard ifStillCurrent?() ?? true else {
                    await self.rollbackStaleReconnectPersistenceIfNeeded(
                        persistedMacDeviceID: ticket.macDeviceID,
                        reconnectSourceMacDeviceID: reconnectSourceMacDeviceID,
                        previousPersistedMac: previousPersistedMac,
                        previousActiveMac: previousActiveMac,
                        scope: scope,
                        store: pairedMacStore
                    )
                    return
                }
                if let scope {
                    guard await self.isScopeCurrent(scope) else { return }
                }
                if clearsForgottenMac {
                    await self.clearForgottenMacDeviceID(ticket.macDeviceID, scope: scope)
                    guard ifStillCurrent?() ?? true else { return }
                }
                self.hasKnownPairedMac = true
            } catch {
                mobileShellLog.error("paired mac store upsert failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Rolls back a cancellation-insensitive upsert when Forget revoked the
    /// stored route that produced a ticket for a different real Mac identity.
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
            mobileShellLog.error("stale reconnect persistence rollback failed mac=\(persistedMacDeviceID, privacy: .private) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Removes a stale reconnect write after Forget records the same scoped tombstone.
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
            mobileShellLog.error("stale paired mac cleanup failed mac=\(macDeviceID, privacy: .private) error=\(String(describing: error), privacy: .public)")
        }
    }
}
