import CmuxMobilePairedMac
import Foundation

/// A cached reconnect's durable write after the store-backed reconnect lane retires.
///
/// This value owns every dependency needed across store suspension points. The
/// lifecycle task awaiting it therefore never has to retain `MobileShellComposite`.
/// The reconnect fence is checked before and after each mutation, and a write that
/// loses authority while suspended is rolled back before the serialized write
/// chain advances to a newer user action.
@MainActor
struct DeferredStoredMacReconnectPersistence {
    let request: StoredMacReconnectPersistenceRequest
    let store: any MobilePairedMacStoring
    let forgottenStore: any PairedMacForgottenStoring
    let forgottenScopeKeys: [String]
    let scope: MobileShellScopeSnapshot
    let fence: SynchronousGenerationBoundary
    let fenceGeneration: UInt64
    let progress: StoredMacReconnectProgress

    func run() async -> DeferredStoredMacReconnectPersistenceResult {
        guard ownsFence else { return .skipped }
        let scopedMacs = (try? await store.loadAll(
            stackUserID: scope.userID,
            teamID: scope.teamID
        )) ?? []
        guard ownsFence else { return .skipped }

        let matchingMacs = scopedMacs.filter {
            $0.macDeviceID == request.ticket.macDeviceID
        }
        let existing = matchingMacs.first {
            $0.stackUserID == scope.userID && $0.teamID == scope.teamID
        }
        let displayFallbackMac = existing
            ?? matchingMacs.first { $0.stackUserID == scope.userID }
            ?? matchingMacs.first
        let storedTag = existing?.instanceTag ?? displayFallbackMac?.instanceTag
        let displayName = request.displayName
            ?? request.ticket.macDisplayName
            ?? displayFallbackMac?.displayName
        let previousActiveMac = try? await store.activeMac(
            stackUserID: scope.userID,
            teamID: scope.teamID
        )
        guard ownsFence else { return .skipped }

        let preservesUnclaimedAuthority = request.reportedInstanceTag == nil
            && request.storedAuthorityMac?.instanceTag == nil
        let instanceTag = preservesUnclaimedAuthority
            ? nil
            : request.resolvedInstanceTag
        let authorityIsUnchanged = preservesUnclaimedAuthority
            || request.resolvedInstanceTag == storedTag
        let storedRoutes = displayFallbackMac?.routes ?? []
        let routes = authorityIsUnchanged
            && request.ticket.routes.count == 1 && !storedRoutes.isEmpty
            ? MobileShellComposite.mergedReconnectRoutes(
                ticketRoutes: request.ticket.routes,
                storedRoutes: storedRoutes
            )
            : request.ticket.routes

        do {
            if preservesUnclaimedAuthority {
                let accepted = try await store.upsertRoutesIfAuthorized(
                    macDeviceID: request.ticket.macDeviceID,
                    displayName: displayName,
                    routes: routes,
                    condition: .unclaimed,
                    markActive: true,
                    stackUserID: scope.userID,
                    teamID: scope.teamID,
                    now: Date()
                )
                guard accepted else { return .skipped }
            } else {
                try await store.upsert(
                    macDeviceID: request.ticket.macDeviceID,
                    displayName: displayName,
                    routes: routes,
                    instanceTag: instanceTag,
                    markActive: true,
                    stackUserID: scope.userID,
                    teamID: scope.teamID,
                    now: Date()
                )
            }
        } catch {
            return .skipped
        }

        guard ownsFence else {
            await rollback(
                previousPersistedMac: existing,
                previousActiveMac: previousActiveMac
            )
            return .skipped
        }

        let refreshedMacs = (try? await store.loadAll(
            stackUserID: scope.userID,
            teamID: scope.teamID
        )) ?? []
        guard ownsFence else {
            await rollback(
                previousPersistedMac: existing,
                previousActiveMac: previousActiveMac
            )
            return .skipped
        }
        var forgottenIDs = Set<String>()
        for key in forgottenScopeKeys {
            forgottenIDs.formUnion(await forgottenStore.load(scope: key))
            guard ownsFence else {
                await rollback(
                    previousPersistedMac: existing,
                    previousActiveMac: previousActiveMac
                )
                return .skipped
            }
        }
        return .persisted(visibleMacs: refreshedMacs.filter {
            !forgottenIDs.contains($0.macDeviceID)
        })
    }

    private var ownsFence: Bool {
        fence.isCurrent(fenceGeneration)
    }

    private func rollback(
        previousPersistedMac: MobilePairedMac?,
        previousActiveMac: MobilePairedMac?
    ) async {
        let persistedMacDeviceID = request.ticket.macDeviceID
        do {
            if progress.wasForgotten(persistedMacDeviceID) {
                try await store.remove(
                    macDeviceID: persistedMacDeviceID,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            } else if let previousPersistedMac {
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
               !progress.wasForgotten(previousActiveMac.macDeviceID) {
                try await store.setActive(
                    macDeviceID: previousActiveMac.macDeviceID,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            }
        } catch {
            // A subsequent serialized user write still owns the final authority.
        }
    }
}
