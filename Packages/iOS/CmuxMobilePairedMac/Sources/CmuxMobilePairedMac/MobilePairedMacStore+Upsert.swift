public import CMUXMobileCore
public import Foundation
import SQLite3
import os

// MobilePairedMacStore's upserts: writing one paired Mac and its routes within an owner scope.
extension MobilePairedMacStore {
    /// Insert or update one paired Mac within the explicit account/team owner scope.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        _ = try upsertRecord(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now,
            restoredCustomizations: nil,
            onlyIfOlder: false,
            revokeMigrationTailscaleGrants: true
        )
    }

    /// Atomically restore only when the scoped row is absent or strictly older.
    @discardableResult
    public func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        try upsertRecord(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now,
            restoredCustomizations: (customName, customColor, customIcon),
            onlyIfOlder: true,
            revokeMigrationTailscaleGrants: true
        )
    }

    /// Atomically write route authority only while the current scoped row is

    func upsertRecord(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date,
        restoredCustomizations: (String?, String?, String?)?,
        onlyIfOlder: Bool,
        routeWriteCondition: MobilePairedMacRouteWriteCondition? = nil,
        revokeMigrationTailscaleGrants: Bool
    ) throws -> Bool {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let normalizedInputTag = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).instanceTag
        var didWrite = false
        try transaction {
            let recordInstanceTag: String?
            switch routeWriteCondition {
            case .matchingInstanceTag(let expectedInstanceTag):
                recordInstanceTag = CmxMacAppInstanceIdentity(
                    macDeviceID: macDeviceID,
                    instanceTag: expectedInstanceTag
                ).instanceTag
            case .unclaimed:
                recordInstanceTag = nil
            case nil:
                recordInstanceTag = normalizedInputTag
            }
            let ownerKey = Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: recordInstanceTag
            )
            let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey)
            let selectedUnclaimed = recordInstanceTag == nil ? nil : try fetchMacRow(
                macDeviceID: macDeviceID,
                ownerKey: Self.ownerKey(
                    stackUserID: stackUserID,
                    teamID: teamID,
                    instanceTag: nil
                )
            )
            let teamlessExact = existing == nil && teamID != nil ? try fetchMacRow(
                macDeviceID: macDeviceID,
                ownerKey: Self.ownerKey(
                    stackUserID: stackUserID,
                    teamID: nil,
                    instanceTag: recordInstanceTag
                )
            ) : nil
            let teamlessUnclaimed = existing == nil && selectedUnclaimed == nil
                && teamID != nil && recordInstanceTag != nil ? try fetchMacRow(
                    macDeviceID: macDeviceID,
                    ownerKey: Self.ownerKey(
                        stackUserID: stackUserID,
                        teamID: nil,
                        instanceTag: nil
                    )
                ) : nil
            let claimable = existing == nil
                ? (selectedUnclaimed ?? teamlessExact ?? teamlessUnclaimed)
                : nil
            let current = existing ?? claimable
            if routeWriteCondition == .unclaimed {
                guard !(try hasClaimedSibling(
                    macDeviceID: macDeviceID,
                    stackUserID: stackUserID,
                    teamID: teamID
                )) else { return }
            }
            if onlyIfOlder, recordInstanceTag == nil {
                guard !(try hasClaimedSibling(
                    macDeviceID: macDeviceID,
                    stackUserID: stackUserID,
                    teamID: teamID
                )) else { return }
            }
            if onlyIfOlder, recordInstanceTag == nil, current?.instanceTag != nil {
                // An authority-less backup cannot identify the process that
                // supplied its host tuple. Reject the whole tuple instead of
                // combining its routes or freshness with retained authority.
                return
            }
            if let routeWriteCondition {
                switch routeWriteCondition {
                case .matchingInstanceTag(let expectedInstanceTag):
                    guard let current,
                          CmxMacAppInstanceIdentity(
                              macDeviceID: current.macDeviceID,
                              instanceTag: current.instanceTag
                          ).id == CmxMacAppInstanceIdentity(
                              macDeviceID: macDeviceID,
                              instanceTag: expectedInstanceTag
                          ).id else { return }
                case .unclaimed:
                    guard current?.instanceTag == nil else { return }
                }
            }
            if onlyIfOlder, let current, current.lastSeenAt >= now {
                return
            }
            let shouldMarkActive: Bool
            if routeWriteCondition != nil {
                shouldMarkActive = markActive ?? current?.isActive ?? false
            } else if onlyIfOlder, let current {
                // Preserve the target's live selection state. Restore computed
                // its flag before this transaction, while set/clearActive may
                // have changed it without changing lastSeenAt.
                shouldMarkActive = current.isActive
            } else if onlyIfOlder, markActive == true {
                // A missing backup-active row may claim selection only when no
                // live row became active after restore's initial snapshot.
                shouldMarkActive = try !hasOtherActiveMac(
                    thanOwnerKey: ownerKey,
                    macDeviceID: macDeviceID,
                    stackUserID: stackUserID,
                    teamID: teamID
                )
            } else {
                shouldMarkActive = markActive ?? false
            }
            if shouldMarkActive {
                try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            }
            if let claimable {
                try moveMacRowScope(
                    macDeviceID: macDeviceID,
                    fromOwnerKey: claimable.ownerKey,
                    toOwnerKey: ownerKey,
                    teamID: teamID
                )
            }
            let existingRoutes: [CmxAttachRoute]
            if existing != nil || claimable != nil {
                existingRoutes = try fetchRoutes(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey
                )
            } else {
                existingRoutes = []
            }
            let removedRouteKeys = try fetchRouteRemovalKeys(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey
            )
            let incomingHasIroh = routes.contains { $0.kind == .iroh }
            let pinnedIrohRoutes = existingRoutes.filter { $0.kind == .iroh }
            let userAuthorizedTailscaleRoutes = try fetchLegacyTailscaleRoutes(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                origin: "user"
            )
            let explicitlyGrantedRouteKeys = Set<String>(
                try fetchLegacyTailscaleRoutes(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey
                ).compactMap { route in
                    guard let endpoint = try? Self.encodeRouteEndpoint(route) else { return nil }
                    return "\(route.kind.rawValue)\u{1F}\(endpoint)"
                }
            )
            // A presence or backup refresh can publish only Iroh and Debug
            // routes after the user explicitly paired over Tailscale. Keep the
            // exact user-authorized endpoint in the visible route set while it
            // is still present in the prior route snapshot. This does not
            // resurrect a route the user removed: removeRoute writes a tombstone
            // and therefore removes it from existingRoutes before this merge.
            let retainedUserAuthorizedTailscaleRoutes = existingRoutes.filter { route in
                route.kind == .tailscale
                    && userAuthorizedTailscaleRoutes.contains {
                        $0.endpoint == route.endpoint
                    }
            }
            // Iroh capability is sticky for one paired Mac. Presence, backup, or
            // an older host build may temporarily publish only raw private-network
            // routes; replacing the stored Iroh identity in that case would allow
            // a later admission failure to downgrade into Stack-bearer RPC. A new
            // Iroh route replaces the old identity normally.
            var routesToPersist: [CmxAttachRoute] = []
            routesToPersist.reserveCapacity(routes.count + pinnedIrohRoutes.count)
            for route in routes {
                let endpoint = try Self.encodeRouteEndpoint(route)
                let key = "\(route.kind.rawValue)\u{1F}\(endpoint)"
                let wildcardKey =
                    "\(route.kind.rawValue)\u{1F}\(Self.routeRemovalWildcardEndpoint)"
                guard !removedRouteKeys.contains(key),
                      !(removedRouteKeys.contains(wildcardKey)
                        && !explicitlyGrantedRouteKeys.contains(key)) else { continue }
                routesToPersist.append(route)
            }
            if !pinnedIrohRoutes.isEmpty, !incomingHasIroh {
                routesToPersist.append(contentsOf: pinnedIrohRoutes)
            }
            for retainedRoute in retainedUserAuthorizedTailscaleRoutes
                where !routesToPersist.contains(where: {
                    $0.kind == retainedRoute.kind
                        && $0.endpoint == retainedRoute.endpoint
                }) {
                routesToPersist.append(retainedRoute)
            }
            let createdAt = existing?.createdAt ?? claimable?.createdAt ?? now
            let persistedInstanceTag = routeWriteCondition == nil
                ? instanceTag
                : current?.instanceTag
            try upsertMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                instanceTag: persistedInstanceTag,
                stackUserID: stackUserID,
                teamID: teamID,
                createdAt: createdAt,
                lastSeenAt: now,
                isActive: shouldMarkActive
            )
            if revokeMigrationTailscaleGrants,
               routesToPersist.contains(where: { $0.kind == .iroh }) {
                // Only the staggered-update migration capability dies on Iroh
                // arrival. A user-entered pairing-code grant is a deliberate
                // Tailscale choice and remains available for preference-ordered
                // dials until its row is removed.
                try exec(
                    """
                    DELETE FROM legacy_tailscale_route_grants
                    WHERE mac_device_id = ? AND owner_key = ? AND origin = 'migration';
                    """,
                    binding: [.text(macDeviceID), .text(ownerKey)]
                )
            }
            if existing != nil, let selectedUnclaimed,
               selectedUnclaimed.ownerKey != ownerKey {
                try exec(
                    "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                    binding: [.text(macDeviceID), .text(selectedUnclaimed.ownerKey)]
                )
            }
            try exec(
                "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text(ownerKey)]
            )
            for route in routesToPersist {
                guard let persistedRoute = route.disclosed(
                    for: .authenticated,
                    at: now
                ) else {
                    continue
                }
                let encoded = try Self.encodeRoute(persistedRoute)
                try exec("""
                    INSERT INTO mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
                    VALUES (?, ?, ?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(route.id),
                    .text(route.kind.rawValue),
                    .text(encoded),
                    .int(Int64(route.priority)),
                ])
            }
            if let restoredCustomizations {
                try exec("""
                    UPDATE paired_macs
                    SET custom_name = ?, custom_color = ?, custom_icon = ?
                    WHERE mac_device_id = ? AND owner_key = ?;
                """, binding: [
                    restoredCustomizations.0.map(BindValue.text) ?? .null,
                    restoredCustomizations.1.map(BindValue.text) ?? .null,
                    restoredCustomizations.2.map(BindValue.text) ?? .null,
                    .text(macDeviceID),
                    .text(ownerKey),
                ])
            }
            didWrite = true
        }
        return didWrite
    }
}
