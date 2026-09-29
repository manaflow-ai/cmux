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
    /// Returns false when persistence fails or a no-tag fresh attach finds an
    /// existing tagged owner.
    @discardableResult
    func persistPairedMacFromTicket(
        _ ticket: CmxAttachTicket,
        instanceTagUpdate: PairedMacInstanceTagUpdate = .preserve,
        displayNameOverride: String? = nil,
        markActive: Bool = true,
        requiredScope: MobileShellScopeSnapshot? = nil,
        userAuthorizedTailscaleRoutes: [CmxAttachRoute] = [],
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        guard let pairedMacStore,
              !ticket.macDeviceID.isEmpty,
              ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return true }
        let stackUserID = identityProvider?.currentUserID
        let startedAt = appDiagnosticNow()
        recordAppEvent(
            .pairedMacStoreWriteStarted,
            correlationID: ticket.macDeviceID
        )
        let scope = await currentScopeSnapshot(userID: stackUserID)
        let ticketDisplayName = displayNameOverride ?? ticket.macDisplayName
        var accepted = true
        await performSerializedPairedMacWrite(ifStillCurrent: ifStillCurrent) { [weak self] in
            guard let self else {
                accepted = false
                return
            }
            if let requiredScope {
                guard scope == requiredScope else {
                    accepted = false
                    return
                }
            }
            if let scope, await !self.isScopeCurrent(scope) {
                accepted = false
                self.recordAppEvent(
                    .pairedMacStoreWriteFailed,
                    correlationID: ticket.macDeviceID,
                    startedAt: startedAt,
                    failure: .superseded
                )
                return
            }
            let scopedMacs = (try? await pairedMacStore.loadAll(
                stackUserID: stackUserID, teamID: scope?.teamID
            )) ?? []
            let expectedStoredTag: String?
            switch instanceTagUpdate {
            case .preserve:
                expectedStoredTag = self.activeMacInstanceTag
            case .preserveOnlyIfUnclaimed:
                expectedStoredTag = nil
            case .replace(let reportedTag):
                expectedStoredTag = reportedTag
            }
            let exactExisting = scopedMacs.first {
                MacPairingKey($0) == MacPairingKey(
                    macDeviceID: ticket.macDeviceID,
                    instanceTag: expectedStoredTag
                )
            }
            let physicalMatches = scopedMacs.filter {
                MacPairingKey($0).isOnDevice(ticket.macDeviceID)
            }
            let existing: MobilePairedMac?
            if let exactExisting {
                existing = exactExisting
            } else if case .preserve = instanceTagUpdate,
                      expectedStoredTag == nil {
                // Before the foreground status probe reports its tag, the
                // selected row is the only safe authority fallback. Never pick
                // an arbitrary sibling merely because it was seen more recently.
                existing = physicalMatches.first(where: \.isActive)
                    ?? (physicalMatches.count == 1 ? physicalMatches[0] : nil)
            } else {
                existing = nil
            }
            let storedTag = existing?.instanceTag
            var displayName = ticketDisplayName ?? existing?.displayName
            if displayName == nil {
                let knownMacs = (try? await pairedMacStore.loadAll(
                    stackUserID: nil, teamID: scope?.teamID
                )) ?? []
                displayName = knownMacs.first {
                    MacPairingKey($0) == MacPairingKey(
                        macDeviceID: ticket.macDeviceID,
                        instanceTag: expectedStoredTag
                    )
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
                        markActive: markActive,
                        stackUserID: stackUserID,
                        teamID: scope?.teamID,
                        now: Date()
                    )
                    guard accepted else {
                        self.recordAppEvent(
                            .pairedMacStoreWriteFailed,
                            correlationID: ticket.macDeviceID,
                            startedAt: startedAt,
                            failure: .authorizationFailed
                        )
                        self.recordAppEvent(
                            .computerRoutesUpdated,
                            correlationID: ticket.macDeviceID,
                            startedAt: startedAt,
                            failure: .authorizationFailed,
                            count: routes.count
                        )
                        return
                    }
                } else {
                    try await pairedMacStore.upsert(
                        macDeviceID: ticket.macDeviceID,
                        displayName: displayName,
                        routes: routes,
                        instanceTag: instanceTag,
                        markActive: markActive,
                        stackUserID: stackUserID,
                        teamID: scope?.teamID,
                        now: Date()
                    )
                }
                if !userAuthorizedTailscaleRoutes.isEmpty,
                   ticket.routes.contains(where: { $0.kind == .iroh }) {
                    // The code named the Mac's device key: its Tailscale
                    // endpoints become Direct addresses, verified by that key.
                    // Merge against the row as it exists AFTER the upsert:
                    // instance-tag adoption can move the row to a new owner
                    // key, and merging against the pre-upsert snapshot would
                    // overwrite the user's existing Direct addresses.
                    // A failed re-read must not masquerade as an empty list:
                    // merging against [] would overwrite the user's existing
                    // addresses. Without the row, keep the grant and skip.
                    let reloaded = (try? await pairedMacStore.loadAll(
                        stackUserID: stackUserID, teamID: scope?.teamID
                    ))?.first {
                        MacPairingKey($0) == MacPairingKey(macDeviceID: ticket.macDeviceID, instanceTag: instanceTag)
                    }
                    if let reloaded {
                        let current = reloaded.directAddresses
                        let merged = current.appendingTailscaleAddresses(
                            from: userAuthorizedTailscaleRoutes,
                            transport: MobilePairedMacDirectAddress.directQuicTransport)
                        do {
                            if merged != current {
                                try await pairedMacStore.setDirectAddresses(
                                    macDeviceID: ticket.macDeviceID,
                                    instanceTag: instanceTag,
                                    rawJSON: MobilePairedMac.encodeDirectAddresses(merged),
                                    stackUserID: stackUserID,
                                    teamID: scope?.teamID
                                )
                            }
                            // Revoke only once the replacement address is
                            // durably saved: the grants are superseded by the
                            // Direct list, and a removed address must not
                            // stay dialable through the compatibility path —
                            // but losing BOTH would strand the pairing.
                            try await pairedMacStore.revokeAllLegacyTailscaleGrants(
                                macDeviceID: ticket.macDeviceID,
                                instanceTag: instanceTag,
                                stackUserID: stackUserID,
                                teamID: scope?.teamID
                            )
                        } catch {
                            // The scanned authorization could not be saved,
                            // and a keyed pairing can never dial a legacy
                            // grant (its stored Iroh route disables the
                            // compatibility path; Direct ignores grants), so
                            // there is no durable fallback. Report failure so
                            // the flow does not dismiss as paired.
                            accepted = false
                            pairedMacPersistenceLog.error(
                                "direct address conversion persist failed: \(String(describing: error), privacy: .private)"
                            )
                            self.recordAppEvent(
                                .pairedMacStoreWriteFailed,
                                correlationID: ticket.macDeviceID,
                                startedAt: startedAt,
                                failure: DiagnosticFailureKind.classify(error)
                            )
                        }
                    } else {
                        accepted = false
                        pairedMacPersistenceLog.error(
                            "direct address conversion skipped: row not found after upsert"
                        )
                        self.recordAppEvent(
                            .pairedMacStoreWriteFailed,
                            correlationID: ticket.macDeviceID,
                            startedAt: startedAt,
                            failure: .unknown
                        )
                    }
                } else if !userAuthorizedTailscaleRoutes.isEmpty {
                    // A pre-Iroh Mac has no device key to verify, so Direct
                    // can never redial it: keep the pairing on the default
                    // Iroh method, whose legacy compatibility dials the grant.
                    // The persisted row is the authority; the published list
                    // may not be loaded yet on a fresh pairing path.
                    let storedMethod = (try? await pairedMacStore.loadAll(
                        stackUserID: stackUserID, teamID: scope?.teamID
                    ))?.first {
                        MacPairingKey($0) == MacPairingKey(macDeviceID: ticket.macDeviceID, instanceTag: instanceTag)
                    }?.connectionMethodRawValue
                    if storedMethod == "direct" {
                        do {
                            try await pairedMacStore.setConnectionMethod(
                                macDeviceID: ticket.macDeviceID,
                                instanceTag: instanceTag,
                                rawValue: nil,
                                stackUserID: stackUserID,
                                teamID: scope?.teamID
                            )
                        } catch {
                            // The row stays pinned to Direct, which ignores
                            // the grant stored below and has no verified
                            // allowlist for a keyless Mac: the reconnect
                            // would strand. Report persistence failure so
                            // the flow does not dismiss as paired.
                            accepted = false
                            pairedMacPersistenceLog.error(
                                "pre-Iroh method reset failed: \(String(describing: error), privacy: .private)"
                            )
                            self.recordAppEvent(
                                .pairedMacStoreWriteFailed,
                                correlationID: ticket.macDeviceID,
                                startedAt: startedAt,
                                failure: DiagnosticFailureKind.classify(error)
                            )
                        }
                    }
                    // Record the device-local grant so the Iroh method's
                    // compatibility can dial it.
                    do {
                        try await pairedMacStore.authorizeUserTailscaleRoutes(
                            macDeviceID: ticket.macDeviceID,
                            instanceTag: instanceTag,
                            stackUserID: stackUserID,
                            teamID: scope?.teamID,
                            routes: userAuthorizedTailscaleRoutes
                        )
                    } catch {
                        pairedMacPersistenceLog.error(
                            "user tailscale grant persist failed: \(String(describing: error), privacy: .private)"
                        )
                        self.recordAppEvent(
                            .computerRoutesUpdated,
                            correlationID: ticket.macDeviceID,
                            startedAt: startedAt,
                            failure: DiagnosticFailureKind.classify(error),
                            count: userAuthorizedTailscaleRoutes.count
                        )
                    }
                }
                await self.clearHiddenMacDeviceID(
                    ticket.macDeviceID,
                    instanceTag: instanceTag,
                    scope: scope
                )
                self.hasKnownPairedMac = true
            } catch {
                accepted = false
                pairedMacPersistenceLog.error(
                    "paired mac upsert failed: \(String(describing: error), privacy: .private)"
                )
                self.recordAppEvent(
                    .pairedMacStoreWriteFailed,
                    correlationID: ticket.macDeviceID,
                    startedAt: startedAt,
                    failure: DiagnosticFailureKind.classify(error)
                )
                self.recordAppEvent(
                    .computerRoutesUpdated,
                    correlationID: ticket.macDeviceID,
                    startedAt: startedAt,
                    failure: DiagnosticFailureKind.classify(error),
                    count: routes.count
                )
            }
        }
        if accepted {
            recordAppEvent(
                .pairedMacStoreWriteSucceeded,
                correlationID: ticket.macDeviceID,
                startedAt: startedAt
            )
            recordAppEvent(
                .computerRoutesUpdated,
                correlationID: ticket.macDeviceID,
                startedAt: startedAt,
                count: ticket.routes.count
            )
        }
        return accepted
    }
}
