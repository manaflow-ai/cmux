public import CMUXMobileCore
public import CmuxPeerTransportCore
public import Foundation

/// The dial inputs for one target Mac binding, derived from a broker
/// discovery snapshot.
public struct PeerDialPlan: Sendable, Equatable {
    public let binding: PeerBrokerBinding
    /// Relay URLs from the binding's published hints.
    public let relayHints: [String]
    /// Globally routable direct `host:port` strings from the published hints.
    public let directHints: [String]
    /// True when the plan came from a discovery fetch performed for this call
    /// (as opposed to a reused snapshot).
    public let fetchedFreshly: Bool

    public init(
        binding: PeerBrokerBinding,
        relayHints: [String],
        directHints: [String],
        fetchedFreshly: Bool
    ) {
        self.binding = binding
        self.relayHints = relayHints
        self.directHints = directHints
        self.fetchedFreshly = fetchedFreshly
    }
}

public struct PeerDiscoveryContextError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Discovery succeeded but no binding matches the requested Mac.
        case bindingNotFound
        /// Discovery failed and no prior context exists.
        case discoveryUnavailable
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// Owns the verified-discovery reuse window for client dials. Three
/// interlocking mechanisms, each covering a recorded failure mode; missing
/// any one reproduces dead-route redial spins or broker quota storms:
///
/// 1. **Failure-classified staleness.** `noteDialFailure` marks a device
///    stale only for unreachable-class failures (or an empty plan);
///    authorization and cancellation failures deliberately do not trigger a
///    refetch. A stale mark bypasses the reuse window exactly once; success
///    clears it.
/// 2. **External invalidation.** Presence pushes call `invalidate` with the
///    device ID they know about.
/// 3. **Single-flight coalescing.** Concurrent dials share one in-flight
///    broker fetch, so a reconnect burst costs one quota unit.
///
/// A reused snapshot that resolves to an empty plan is rebuilt once from
/// fresh discovery; a fresh plan is authoritative. If the fresh fetch fails,
/// the prior context is kept so lower-priority fallbacks still get a chance.
public actor PeerDiscoveryContextProvider {
    private let discover: @Sendable () async throws -> PeerBrokerDiscoverySnapshot
    private let reuseWindow: Duration
    private let now: @Sendable () -> Date

    private var snapshot: PeerBrokerDiscoverySnapshot?
    private var snapshotFetchedAt: Date?
    private var staleDeviceIDs: Set<String> = []
    private var inFlight: Task<PeerBrokerDiscoverySnapshot, any Error>?

    public init(
        reuseWindow: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() },
        discover: @escaping @Sendable () async throws -> PeerBrokerDiscoverySnapshot
    ) {
        self.reuseWindow = reuseWindow
        self.now = now
        self.discover = discover
    }

    /// Resolve the dial plan for one Mac. `macDeviceID` is compared
    /// canonically (lowercased).
    public func dialPlan(
        macDeviceID: String,
        tag: String?
    ) async throws -> PeerDialPlan {
        let key = macDeviceID.lowercased()
        let canReuse =
            !staleDeviceIDs.contains(key)
            && snapshot != nil
            && snapshotFetchedAt.map {
                now().timeIntervalSince($0) < reuseWindow.peerTimeInterval
            } == true

        if canReuse, let snapshot {
            if let plan = Self.plan(in: snapshot, deviceID: key, tag: tag, fresh: false) {
                return plan
            }
            // Reused snapshot resolved empty: rebuild once from fresh
            // discovery. If the refetch fails, surface not-found from the
            // prior context rather than discovery-unavailable.
            if let fresh = try? await sharedDiscover() {
                if let plan = Self.plan(in: fresh, deviceID: key, tag: tag, fresh: true) {
                    staleDeviceIDs.remove(key)
                    return plan
                }
            }
            throw PeerDiscoveryContextError(kind: .bindingNotFound)
        }

        do {
            let fresh = try await sharedDiscover()
            staleDeviceIDs.remove(key)
            guard let plan = Self.plan(in: fresh, deviceID: key, tag: tag, fresh: true) else {
                throw PeerDiscoveryContextError(kind: .bindingNotFound)
            }
            return plan
        } catch let error as PeerDiscoveryContextError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep the prior context alive for fallbacks.
            if let snapshot,
                let plan = Self.plan(in: snapshot, deviceID: key, tag: tag, fresh: false)
            {
                return plan
            }
            throw PeerDiscoveryContextError(kind: .discoveryUnavailable)
        }
    }

    /// Classify a dial outcome. Only unreachable-class failures (or a plan
    /// that was empty when dialed) mark the device stale for refetch.
    public func noteDialFailure(
        macDeviceID: String,
        classification: PeerDialFailure.Class,
        planWasEmpty: Bool
    ) {
        guard classification == .unreachable || planWasEmpty else { return }
        staleDeviceIDs.insert(macDeviceID.lowercased())
    }

    public func noteDialSuccess(macDeviceID: String) {
        staleDeviceIDs.remove(macDeviceID.lowercased())
    }

    /// Presence pushes know the device, not the endpoint.
    public func invalidate(macDeviceID: String) {
        staleDeviceIDs.insert(macDeviceID.lowercased())
    }

    public func invalidateAll() {
        snapshot = nil
        snapshotFetchedAt = nil
        staleDeviceIDs.removeAll()
    }

    private func sharedDiscover() async throws -> PeerBrokerDiscoverySnapshot {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { [discover] in
            try await discover()
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            let fresh = try await task.value
            snapshot = fresh
            snapshotFetchedAt = now()
            return fresh
        } catch {
            throw error
        }
    }

    private static func plan(
        in snapshot: PeerBrokerDiscoverySnapshot,
        deviceID: String,
        tag: String?,
        fresh: Bool
    ) -> PeerDialPlan? {
        let candidates = snapshot.bindings.filter { binding in
            binding.deviceID.lowercased() == deviceID
                && (tag == nil || binding.tag == tag)
        }
        // Tag-less lookups matching two differently tagged sibling builds
        // fail closed rather than routing to whichever sorts first.
        if tag == nil, Set(candidates.map(\.tag)).count > 1 {
            return nil
        }
        guard let binding = candidates.first else { return nil }
        let relayHints = binding.pathHints
            .filter { $0.kind == .relayURL }
            .map(\.value)
        let directHints = binding.pathHints
            .filter { $0.kind != .relayURL }
            .map(\.value)
        return PeerDialPlan(
            binding: binding,
            relayHints: relayHints,
            directHints: directHints,
            fetchedFreshly: fresh
        )
    }
}

extension Duration {
    fileprivate var peerTimeInterval: TimeInterval {
        TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
