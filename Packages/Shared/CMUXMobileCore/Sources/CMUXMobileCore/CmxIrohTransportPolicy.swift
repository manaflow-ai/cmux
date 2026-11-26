import Foundation

extension CmxAttachEndpoint {
    /// Creates an Iroh endpoint from the legacy peer fields.
    ///
    /// This compatibility constructor preserves existing source and wire
    /// producers while new code moves to ``peer(identity:pathHints:)``.
    /// Legacy direct addresses have no provenance or expiry, so they decode as
    /// private, fallback-only, and unusable until refreshed by a current source.
    /// - Parameters:
    ///   - id: The Iroh EndpointID.
    ///   - relayHint: The optional legacy relay identifier.
    ///   - directAddrs: Legacy direct socket addresses.
    ///   - relayURL: The optional relay URL.
    /// - Returns: A peer endpoint with identity separated from path hints.
    public static func peer(
        id: String,
        relayHint: String?,
        directAddrs: [String],
        relayURL: String?
    ) throws -> Self {
        var pathHints: [CmxIrohPathHint] = []
        if let relayHint {
            pathHints.append(CmxIrohPathHint(
                legacyKind: .relayIdentifier,
                value: relayHint,
                privacyScope: .publicInternet
            ))
        }
        pathHints.append(contentsOf: directAddrs.map { address in
            CmxIrohPathHint(
                legacyKind: .directAddress,
                value: address,
                privacyScope: .privateNetwork
            )
        })
        if let relayURL {
            pathHints.append(CmxIrohPathHint(
                legacyKind: .relayURL,
                value: relayURL,
                privacyScope: .publicInternet
            ))
        }
        return .peer(
            identity: try CmxIrohPeerIdentity(endpointID: id),
            pathHints: pathHints
        )
    }

    /// The Iroh identity carried by a peer endpoint, independent of its hints.
    public var irohPeerIdentity: CmxIrohPeerIdentity? {
        guard case let .peer(identity, _) = self else {
            return nil
        }
        return identity
    }

    /// Builds the explicit two-attempt Iroh dial plan.
    ///
    /// A profile-scoped hint is omitted unless its overlay/site/profile is
    /// currently active, preventing an overlapping private address from being
    /// attempted on the wrong network.
    /// - Parameters:
    ///   - now: The time against which hint expiry is checked.
    ///   - managedRelayURLs: The exact relay URLs configured by cmux. Relay
    ///     hints outside this set and legacy relay identifiers are excluded.
    ///   - activeNetworkProfiles: Locally verified provider-qualified profiles.
    /// - Returns: A two-phase plan for peer endpoints, otherwise `nil`.
    public func irohDialPlan(
        at now: Date,
        managedRelayURLs: Set<String>,
        activeNetworkProfiles: Set<CmxIrohNetworkProfileKey> = []
    ) -> CmxIrohDialPlan? {
        guard case let .peer(_, pathHints) = self else {
            return nil
        }
        let publicPaths = pathHints.filter { hint in
            guard hint.privacyScope == .publicInternet,
                  hint.isUsable(at: now) else {
                return false
            }
            switch hint.kind {
            case .directAddress:
                return true
            case .relayURL:
                return managedRelayURLs.contains(hint.value)
            case .relayIdentifier:
                return false
            }
        }
        let privateFallbackPaths = pathHints.filter { hint in
            guard hint.privacyScope != .publicInternet,
                  hint.isUsable(at: now),
                  let networkProfile = hint.networkProfile else {
                return false
            }
            return activeNetworkProfiles.contains(networkProfile)
        }
        return CmxIrohDialPlan(
            publicPaths: publicPaths,
            privateFallbackPaths: privateFallbackPaths
        )
    }
}

extension CmxAttachEndpoint {
    /// Returns a copy whose Iroh hints are current and permitted at a
    /// serialization boundary.
    fileprivate func disclosed(
        for disclosure: CmxAttachRouteDisclosure,
        at now: Date
    ) -> Self {
        guard case let .peer(identity, pathHints) = self else {
            return self
        }
        let disclosedHints: [CmxIrohPathHint]
        switch disclosure {
        case .authenticated:
            disclosedHints = pathHints.filter { $0.isUsable(at: now) }
        case .cloudRendezvous, .pairedMacCloudBackup:
            disclosedHints = pathHints.compactMap { hint in
                guard hint.kind == .relayURL else { return nil }
                return hint.publicDisclosure(at: now)
            }
        case .publicStatus, .pairingQRCode:
            disclosedHints = []
        }
        return .peer(identity: identity, pathHints: disclosedHints)
    }
}

extension CmxAttachRoute {
    /// Returns the route shape permitted at a serialization boundary.
    ///
    /// Unauthenticated status exposes no attach routes. Cloud rendezvous,
    /// pairing QR, and paired-Mac backup keep only the route data permitted by
    /// their stricter disclosure policies.
    public func disclosed(
        for disclosure: CmxAttachRouteDisclosure,
        at now: Date
    ) -> Self? {
        if disclosure == .publicStatus {
            return nil
        }
        return try? Self(
            id: id,
            kind: kind,
            endpoint: endpoint.disclosed(for: disclosure, at: now),
            priority: priority
        )
    }
}

extension CmxAttachTicket {
    /// Returns a ticket whose routes are safe for an authenticated transport.
    ///
    /// Pairing QR and public-status payloads intentionally have different
    /// field-level disclosure rules, so they must not use this copy operation.
    public func authenticatedDisclosure(at now: Date) throws -> Self {
        try Self(
            version: version,
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes.compactMap {
                $0.disclosed(for: .authenticated, at: now)
            },
            expiresAt: expiresAt,
            authToken: authToken
        )
    }
}
