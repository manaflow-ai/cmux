public import CMUXMobileCore

extension MobilePairedMacStore {
    /// Persist `'user'`-origin Tailscale compatibility grants for routes the
    /// user entered explicitly. Upgrades an existing `'migration'` grant for
    /// the same destination to `'user'`, so a deliberate re-scan is not
    /// silently revoked when Iroh is later persisted.
    public func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) throws {
        try ensureReady()
        let canonicalMacDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let ownerKey = Self.ownerKey(
            stackUserID: stackUserID,
            teamID: teamID,
            instanceTag: instanceTag
        )
        let grantRoutes = validatedUserTailscaleRoutes(routes)
        guard !grantRoutes.isEmpty else { return }
        try transaction {
            try insertUserTailscaleGrants(
                grantRoutes,
                macDeviceID: canonicalMacDeviceID,
                ownerKey: ownerKey
            )
        }
    }

    /// Records a user grant and its Tailscale method in one SQLite transaction.
    public func authorizeUserTailscaleRoutesAndSetConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute],
        rawValue: String
    ) throws {
        try ensureReady()
        let canonicalMacDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let ownerKey = Self.ownerKey(
            stackUserID: stackUserID,
            teamID: teamID,
            instanceTag: instanceTag
        )
        let grantRoutes = validatedUserTailscaleRoutes(routes)
        guard !grantRoutes.isEmpty else { return }
        try transaction {
            try insertUserTailscaleGrants(
                grantRoutes,
                macDeviceID: canonicalMacDeviceID,
                ownerKey: ownerKey
            )
            try exec("""
                UPDATE paired_macs
                SET connection_method = ?
                WHERE mac_device_id = ? AND owner_key = ?;
            """, binding: [
                .text(rawValue),
                .text(canonicalMacDeviceID),
                .text(ownerKey),
            ])
        }
    }

    private func validatedUserTailscaleRoutes(
        _ routes: [CmxAttachRoute]
    ) -> [CmxAttachRoute] {
        routes.filter { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else { return false }
            return (try? CmxUserTailscalePairingAuthorization(host: host, port: port)) != nil
        }
    }

    private func insertUserTailscaleGrants(
        _ routes: [CmxAttachRoute],
        macDeviceID: String,
        ownerKey: String
    ) throws {
        guard try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey) != nil else {
            // The grant table references the scoped row; authorizing an
            // unknown row would strand an unowned bearer capability.
            return
        }
        for route in routes {
            let encoded = try MobilePairedMacStore.encodeRoute(route)
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
        }
    }
}
