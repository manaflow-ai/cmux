public import CMUXMobileCore
public import Foundation
import SQLite3
import os

// MobilePairedMacStore's route authority: conditional route writes and removals, route
// tombstones, and the device-local Tailscale compatibility grants.
extension MobilePairedMacStore {
    /// still authorized by `condition`.
    @discardableResult
    public func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        try upsertRecord(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: nil,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now,
            restoredCustomizations: nil,
            onlyIfOlder: false,
            routeWriteCondition: condition,
            revokeMigrationTailscaleGrants: false
        )
    }

    /// Remove one route from a scoped pairing and persist an endpoint tombstone
    /// so later registry/presence refreshes cannot resurrect it on this device.
    @discardableResult
    public func removeRouteIfAuthorized(
        macDeviceID: String,
        route: CmxAttachRoute,
        condition: MobilePairedMacRouteWriteCondition,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        guard route.kind != .iroh else { return false }
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let instanceTag: String?
        switch condition {
        case .matchingInstanceTag(let tag): instanceTag = tag
        case .unclaimed: instanceTag = nil
        }
        let ownerKey = Self.ownerKey(
            stackUserID: stackUserID,
            teamID: teamID,
            instanceTag: instanceTag
        )
        var didWrite = false
        try transaction {
            guard let current = try fetchMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey
            ) else { return }
            switch condition {
            case .matchingInstanceTag(let expected):
                guard CmxMacAppInstanceIdentity(
                    macDeviceID: current.macDeviceID,
                    instanceTag: current.instanceTag
                ).id == CmxMacAppInstanceIdentity(
                    macDeviceID: macDeviceID,
                    instanceTag: expected
                ).id else { return }
            case .unclaimed:
                guard current.instanceTag == nil,
                      !(try hasClaimedSibling(
                          macDeviceID: macDeviceID,
                          stackUserID: stackUserID,
                          teamID: teamID
                      )) else { return }
            }

            let currentRoutes = try fetchRoutes(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey
            )
            // Endpoint and transport kind are the authoritative identity. A
            // refreshed registry can reuse a route id for another endpoint,
            // so accepting an id-only match could delete the wrong route.
            guard let removedIndex = currentRoutes.firstIndex(where: {
                $0.kind == route.kind && $0.endpoint == route.endpoint
            }) else {
                // A compatibility grant can outlive the route snapshot after
                // a refresh. Revoke that stale bearer and park its endpoint
                // even though there is no route row left to rewrite.
                guard route.kind == .tailscale,
                      try revokeLegacyTailscaleGrant(
                          macDeviceID: macDeviceID,
                          ownerKey: ownerKey,
                          endpoint: route.endpoint
                      ) else { return }
                let encoded = try Self.encodeRouteEndpoint(route)
                try exec("""
                    INSERT OR IGNORE INTO mac_route_removals (
                        mac_device_id, owner_key, kind, endpoint_json
                    ) VALUES (?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(route.kind.rawValue),
                    .text(encoded),
                ])
                try compactRouteRemovalTombstones(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey,
                    kind: route.kind
                )
                didWrite = true
                return
            }
            let removed = currentRoutes[removedIndex]
            var remaining = currentRoutes
            remaining.remove(at: removedIndex)

            let encoded = try Self.encodeRouteEndpoint(removed)
            try exec("""
                INSERT OR IGNORE INTO mac_route_removals (
                    mac_device_id, owner_key, kind, endpoint_json
                ) VALUES (?, ?, ?, ?);
            """, binding: [
                .text(macDeviceID),
                .text(ownerKey),
                .text(removed.kind.rawValue),
                .text(encoded),
            ])
            try compactRouteRemovalTombstones(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                kind: removed.kind
            )
            _ = try revokeLegacyTailscaleGrant(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                endpoint: removed.endpoint
            )
            guard !remaining.isEmpty else {
                try upsertMacRow(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey,
                    displayName: current.displayName,
                    instanceTag: current.instanceTag,
                    stackUserID: current.stackUserID,
                    teamID: current.teamID,
                    createdAt: current.createdAt,
                    lastSeenAt: now,
                    isActive: current.isActive
                )
                try exec(
                    "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
                    binding: [.text(macDeviceID), .text(ownerKey)]
                )
                didWrite = true
                return
            }
            try upsertMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: current.displayName,
                instanceTag: current.instanceTag,
                stackUserID: current.stackUserID,
                teamID: current.teamID,
                createdAt: current.createdAt,
                lastSeenAt: now,
                isActive: current.isActive
            )
            try exec(
                "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text(ownerKey)]
            )
            for remainingRoute in remaining {
                guard let disclosed = remainingRoute.disclosed(
                    for: .authenticated,
                    at: now
                ) else { continue }
                try exec("""
                    INSERT INTO mac_routes (
                        mac_device_id, owner_key, route_id, kind, endpoint_json, priority
                    ) VALUES (?, ?, ?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(remainingRoute.id),
                    .text(remainingRoute.kind.rawValue),
                    .text(try Self.encodeRoute(disclosed)),
                    .int(Int64(remainingRoute.priority)),
                ])
            }
            didWrite = true
        }
        return didWrite
    }

    /// A route removal also revokes its device-local compatibility grant. The
    /// grant stores the full route JSON, while route identity is endpoint-based
    /// so a refreshed route id or metadata cannot leave an old bearer behind.
    private func revokeLegacyTailscaleGrant(
        macDeviceID: String,
        ownerKey: String,
        endpoint: CmxAttachEndpoint
    ) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_prepare_v2(
            db,
            "SELECT endpoint_json FROM legacy_tailscale_route_grants WHERE mac_device_id = ? AND owner_key = ?;",
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(result, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(macDeviceID), .text(ownerKey)])
        let decoder = JSONDecoder()
        var encodedMatches: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = Self.readNullableText(statement, column: 0),
                  let data = raw.data(using: .utf8),
                  let route = try? decoder.decode(CmxAttachRoute.self, from: data),
                  route.kind == .tailscale,
                  route.endpoint == endpoint else { continue }
            encodedMatches.append(raw)
        }
        for encoded in encodedMatches {
            try exec(
                "DELETE FROM legacy_tailscale_route_grants WHERE mac_device_id = ? AND owner_key = ? AND endpoint_json = ?;",
                binding: [.text(macDeviceID), .text(ownerKey), .text(encoded)]
            )
        }
        return !encodedMatches.isEmpty
    }

    /// Persist `'user'`-origin Tailscale compatibility grants for routes the
    /// user entered as a pairing code. Upgrades an existing `'migration'` grant
    /// for the same destination to `'user'`, so a deliberate re-scan is not
    /// silently revoked when Iroh is later persisted.
    public func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let ownerKey = Self.ownerKey(
            stackUserID: stackUserID,
            teamID: teamID,
            instanceTag: instanceTag
        )
        let grantRoutes = routes.filter { route in
            guard route.kind == .tailscale,
                  case .hostPort = route.endpoint else { return false }
            return true
        }
        guard !grantRoutes.isEmpty else { return }
        try transaction {
            guard try fetchMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey
            ) != nil else {
                // The grant table references the scoped row; authorizing an
                // unknown row would strand an unowned bearer capability.
                return
            }
            var currentRoutes = try fetchRoutes(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey
            )
            // A fresh pairing code replaces the previously authorized
            // Tailscale destination set. Capture all older grants before
            // inserting the incoming routes, including migration grants whose
            // route snapshot may already have been refreshed away.
            let previousGrantedRoutes = try fetchLegacyTailscaleRoutes(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey
            )
            for route in grantRoutes {
                let encoded = try Self.encodeRoute(route)
                let encodedEndpoint = try Self.encodeRouteEndpoint(route)
                _ = try revokeLegacyTailscaleGrant(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey,
                    endpoint: route.endpoint
                )
                try exec("""
                    INSERT INTO legacy_tailscale_route_grants (
                        mac_device_id, owner_key, endpoint_json, origin
                    )
                    VALUES (?, ?, ?, 'user')
                    ON CONFLICT (mac_device_id, owner_key, endpoint_json)
                    DO UPDATE SET origin = 'user';
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(encoded),
                ])
                // A pairing-code scan is a fresh, explicit authorization for
                // this exact destination. Clear only its local deletion marker;
                // passive route refreshes never reach this path and therefore
                // cannot resurrect a route the user removed.
                try exec("""
                    DELETE FROM mac_route_removals
                    WHERE mac_device_id = ?
                      AND owner_key = ?
                      AND kind = ?
                      AND endpoint_json = ?;
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(route.kind.rawValue),
                    .text(encodedEndpoint),
                ])
                // The preceding passive refresh intentionally filtered this
                // endpoint because its tombstone was still present. Reinsert
                // the route as part of this explicit pairing authorization so
                // a successful scan immediately becomes usable again.
                if let disclosed = route.disclosed(for: .authenticated, at: Date()) {
                    currentRoutes.removeAll {
                        $0.kind == disclosed.kind && $0.endpoint == disclosed.endpoint
                    }
                    currentRoutes.append(disclosed)
                }
            }
            for staleRoute in previousGrantedRoutes where !grantRoutes.contains(where: {
                $0.endpoint == staleRoute.endpoint
            }) {
                if let removedIndex = currentRoutes.firstIndex(where: {
                    $0.kind == .tailscale && $0.endpoint == staleRoute.endpoint
                }) {
                    var remaining = currentRoutes
                    remaining.remove(at: removedIndex)
                    if !remaining.isEmpty {
                        currentRoutes = remaining
                    }
                }
                let encodedEndpoint = try Self.encodeRouteEndpoint(staleRoute)
                try exec("""
                    INSERT OR IGNORE INTO mac_route_removals (
                        mac_device_id, owner_key, kind, endpoint_json
                    ) VALUES (?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(staleRoute.kind.rawValue),
                    .text(encodedEndpoint),
                ])
                try compactRouteRemovalTombstones(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey,
                    kind: staleRoute.kind
                )
                _ = try revokeLegacyTailscaleGrant(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey,
                    endpoint: staleRoute.endpoint
                )
            }
            try exec(
                "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text(ownerKey)]
            )
            for route in currentRoutes {
                try exec("""
                    INSERT INTO mac_routes (
                        mac_device_id, owner_key, route_id, kind, endpoint_json, priority
                    ) VALUES (?, ?, ?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(route.id),
                    .text(route.kind.rawValue),
                    .text(try Self.encodeRoute(route)),
                    .int(Int64(route.priority)),
                ])
            }
        }
    }
}
