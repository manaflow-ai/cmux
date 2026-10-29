import Foundation

private struct CmxIrohPathHintMergeKey: Hashable {
    let kind: String
    let value: String
    let source: String
    let networkProfile: CmxIrohNetworkProfileKey?

    init(_ hint: CmxIrohPathHint) {
        kind = hint.kind.rawValue
        value = hint.value
        source = hint.source.rawValue
        networkProfile = hint.networkProfile
    }
}

public extension CmxIrohNetworkProfileKey {
    /// The strongest Tailscale profile iOS can prove without a provider API.
    ///
    /// Apple exposes the active packet tunnel and its assigned addresses, but
    /// not Tailscale's tailnet identifier. This profile therefore means "a
    /// Tailscale tunnel is active on this device." It is routing metadata only;
    /// the Iroh EndpointID remains the peer-authentication authority.
    static let activeTailscaleTunnel: CmxIrohNetworkProfileKey = {
        do {
            return try CmxIrohNetworkProfileKey(
                source: .tailscale,
                profileID: "42e59eea27473bde00430ca3d4a0f34a372713f0b90d46ee1ab2802c6d668979"
            )
        } catch {
            preconditionFailure("The built-in Tailscale network profile is invalid: \(error)")
        }
    }()
}

public extension CmxAttachRoute {
    /// Adds short-lived Tailscale addresses to every existing Iroh route.
    ///
    /// Private paths never contribute identity or authorization. They are
    /// attached only to an existing Iroh EndpointID and remain fallback-only,
    /// so a wrong or stale address can only fail Iroh's authenticated handshake.
    /// Numeric Tailscale validation rejects LAN, public, MagicDNS, service, and
    /// generic host routes. The original raw routes remain in the returned set
    /// for rolling compatibility, but callers continue pinning connection
    /// attempts to Iroh whenever an Iroh route exists.
    static func addingIrohPrivatePaths(
        to routes: [CmxAttachRoute],
        observedAt: Date
    ) -> [CmxAttachRoute] {
        let maximumHintCount = CmxAttachEndpoint.maximumIrohPathHintCount
        var candidateKeys: Set<CmxIrohPathHintMergeKey> = []
        var candidates: [(key: CmxIrohPathHintMergeKey, hint: CmxIrohPathHint)] = []
        candidates.reserveCapacity(maximumHintCount)
        for route in routes where candidates.count < maximumHintCount {
            guard let hint = route.irohTailscalePathHint(observedAt: observedAt) else {
                continue
            }
            let key = CmxIrohPathHintMergeKey(hint)
            guard candidateKeys.insert(key).inserted else { continue }
            candidates.append((key, hint))
        }
        guard !candidates.isEmpty else { return routes }

        return routes.map { route in
            guard route.kind == .iroh,
                  case let .peer(identity, pathHints) = route.endpoint else {
                return route
            }

            let usableHints = pathHints.filter { $0.isUsable(at: observedAt) }
            var existingCounts: [CmxIrohPathHintMergeKey: Int] = [:]
            existingCounts.reserveCapacity(usableHints.count)
            for hint in usableHints {
                existingCounts[CmxIrohPathHintMergeKey(hint), default: 0] += 1
            }

            var removedExistingKeys: Set<CmxIrohPathHintMergeKey> = []
            var appendedCandidates: [CmxIrohPathHint] = []
            appendedCandidates.reserveCapacity(candidates.count)
            var mergedCount = usableHints.count
            for candidate in candidates {
                if let removedCount = existingCounts[candidate.key] {
                    removedExistingKeys.insert(candidate.key)
                    mergedCount -= removedCount
                }
                guard mergedCount < maximumHintCount else { continue }
                appendedCandidates.append(candidate.hint)
                mergedCount += 1
            }

            var hints = usableHints.filter {
                !removedExistingKeys.contains(CmxIrohPathHintMergeKey($0))
            }
            hints.append(contentsOf: appendedCandidates)
            return (try? CmxAttachRoute(
                id: route.id,
                kind: route.kind,
                endpoint: .peer(identity: identity, pathHints: hints),
                priority: route.priority
            )) ?? route
        }
    }

    /// Creates one fallback-only Iroh hint from a canonical Tailscale peer.
    func irohTailscalePathHint(observedAt: Date) -> CmxIrohPathHint? {
        guard kind == .tailscale,
              case let .hostPort(host, port) = endpoint,
              let address = CmxTailscalePeerAddress(host) else {
            return nil
        }
        let socketAddress: String
        switch address.family {
        case .ipv4:
            socketAddress = "\(address.value):\(port)"
        case .ipv6:
            socketAddress = "[\(address.value)]:\(port)"
        }
        return try? CmxIrohPathHint(
            kind: .directAddress,
            value: socketAddress,
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(
                CmxIrohPathHint.maximumPrivateHintTTL
            ),
            networkProfile: .activeTailscaleTunnel
        )
    }
}
