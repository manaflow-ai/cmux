public import CMUXMobileCore
public import Foundation

/// Picks the single Mac a signed-in phone should auto-attach to on the cold-start
/// "sign in → connected" path, from the team-scoped device registry.
///
/// Pure and deterministic: no I/O, no clock reads beyond the injected `now`, so
/// the whole "which Mac, or none" policy is unit-testable without a live
/// connection. The shell turns a returned target into a connection by reusing the
/// proven registry connect path (`connectToRegistryInstance`), which mints the
/// attach ticket Stack-authenticated on the Mac and persists the pairing.
///
/// The contract is conservative on purpose: auto-attach only fires when there is
/// one obvious Mac. Any ambiguity (two online Macs, or two equally-recent Macs
/// with no presence signal) returns `nil` so the caller falls through to the
/// manual pair screen rather than guessing. Same-account safety is structural:
/// the registry is scoped to the signed-in user's team, so a different-account
/// Mac never appears here, and even a stray route would be rejected at mint by
/// the Mac's same-Stack-account authorization check.
public enum MobileAutoAttachTargetSelector {
    /// A device that is a viable auto-attach target: a controllable host with at
    /// least one instance reachable on a supported route.
    public struct Candidate: Equatable, Sendable {
        /// The registry device to auto-attach to.
        public let device: RegistryDevice
        /// The chosen app instance (tag) on `device` whose route the connect uses.
        public let instance: RegistryAppInstance
        /// The more recent of the device's and chosen instance's `lastSeenAt`,
        /// used to rank candidates by recency when there is no presence signal.
        public let lastSeenAt: Date

        /// Creates a candidate from a device, its chosen instance, and the
        /// recency timestamp used to break ties between candidates.
        public init(device: RegistryDevice, instance: RegistryAppInstance, lastSeenAt: Date) {
            self.device = device
            self.instance = instance
            self.lastSeenAt = lastSeenAt
        }
    }

    /// The auto-attach target, or `nil` when there is no single obvious Mac.
    ///
    /// - Parameters:
    ///   - devices: The team's registry devices (the shell's `registryDevices`).
    ///   - supportedRouteKinds: The transports this client can reach (empty =
    ///     accept any kind). A device with no reachable route on these kinds is
    ///     not a candidate.
    ///   - presenceOnlineDeviceIDs: Device ids currently reported online by the
    ///     presence service. Meaningful only when `presenceAvailable` is true.
    ///   - presenceAvailable: Whether a presence signal exists. When false
    ///     (e.g. the presence service is not wired yet), selection falls back to
    ///     recency over all candidates.
    ///   - rejectLoopback: When `true` (a physical phone), loopback routes are
    ///     never considered reachable — a `127.0.0.1` route names the phone
    ///     itself, not the Mac, and loopback is Stack-auth-trusted, so
    ///     auto-dialing it would hand the bearer to a phone-local listener. The
    ///     simulator passes `false` (there `127.0.0.1` IS the host Mac).
    public static func selectTarget(
        devices: [RegistryDevice],
        supportedRouteKinds: [CmxAttachTransportKind],
        presenceOnlineDeviceIDs: Set<String> = [],
        presenceAvailable: Bool = false,
        rejectLoopback: Bool = false,
        now: Date = Date()
    ) -> Candidate? {
        let candidates = devices.compactMap {
            candidate(for: $0, supportedRouteKinds: supportedRouteKinds, rejectLoopback: rejectLoopback)
        }
        guard !candidates.isEmpty else { return nil }

        if presenceAvailable {
            let online = candidates.filter { presenceOnlineDeviceIDs.contains($0.device.deviceId) }
            if online.count == 1 { return online[0] }
            // Two or more live Macs: ambiguous, never guess between them.
            if online.count > 1 { return nil }
            // Zero online: a recently-active Mac may still be reachable; fall
            // through to recency. The connect attempt is bounded and rolls back
            // on failure, so trying a stale-but-reachable Mac is safe.
        }

        return mostRecentUnambiguous(candidates)
    }

    /// The single most-recently-seen candidate, but only when it is strictly more
    /// recent than the next one. A tie returns `nil` so auto-attach never silently
    /// picks between equally-stale Macs.
    private static func mostRecentUnambiguous(_ candidates: [Candidate]) -> Candidate? {
        if candidates.count == 1 { return candidates[0] }
        let sorted = candidates.sorted { $0.lastSeenAt > $1.lastSeenAt }
        guard let first = sorted.first, sorted.count > 1 else { return sorted.first }
        if first.lastSeenAt > sorted[1].lastSeenAt { return first }
        return nil
    }

    /// The best auto-attach candidate for one device, or `nil` if it is not a
    /// controllable host, has no instance reachable on a supported route, or the
    /// two freshest reachable instances are tied on recency (ambiguous tag).
    ///
    /// Among a device's instances, prefer the most-recently-seen instance that has
    /// a usable route (a Mac can run several tagged builds; the freshest reachable
    /// one is the right default). When the freshest two reachable instances share
    /// the same `lastSeenAt`, there is no obvious build to auto-attach to, so this
    /// returns `nil` and the caller falls through to manual pairing rather than
    /// silently connecting to whichever tagged build happened to sort first. This
    /// mirrors the device-level recency-tie rule and the existing reconnect
    /// registry policy, which refuses to auto-pick among multiple instances.
    private static func candidate(
        for device: RegistryDevice,
        supportedRouteKinds: [CmxAttachTransportKind],
        rejectLoopback: Bool
    ) -> Candidate? {
        guard device.isControllableHost else { return nil }
        let reachable = device.instances
            .filter { instance in
                MobileAttachRoutePriority.firstReachableHostPort(
                    instance.routes,
                    supportedKinds: supportedRouteKinds,
                    rejectLoopback: rejectLoopback
                ) != nil
            }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
        guard let instance = reachable.first else { return nil }
        // Ambiguous tag: the freshest two reachable instances are equally recent,
        // so there is no single obvious build to connect to.
        if reachable.count > 1, reachable[1].lastSeenAt == instance.lastSeenAt {
            return nil
        }
        return Candidate(
            device: device,
            instance: instance,
            lastSeenAt: max(device.lastSeenAt, instance.lastSeenAt)
        )
    }
}
