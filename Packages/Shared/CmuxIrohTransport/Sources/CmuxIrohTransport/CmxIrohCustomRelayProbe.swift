public import Foundation

/// Tests a custom relay through a throwaway endpoint without mutating live runtime state.
public struct CmxIrohCustomRelayProbe: Sendable {
    private enum Observation: Sendable {
        case reachable(String)
        case closed
        case timedOut
    }

    private let factory: any CmxIrohEndpointFactory
    private let randomness: any CmxIrohRandomByteGenerating
    private let clock: any CmxIrohRelayClock

    /// Creates an isolated custom relay probe.
    public init(
        factory: any CmxIrohEndpointFactory = CmxIrohLibEndpointFactory(),
        randomness: any CmxIrohRandomByteGenerating = CmxIrohSystemRandomByteGenerator(),
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    ) {
        self.factory = factory
        self.randomness = randomness
        self.clock = clock
    }

    /// Binds a temporary endpoint and waits for one allowed custom relay.
    ///
    /// The endpoint uses a fresh unpersisted key, grants no stream credit, and
    /// is always closed before this method returns.
    public func probe(
        profile: CmxIrohEndpointRelayProfile,
        timeout: TimeInterval = 10
    ) async -> CmxIrohCustomRelayProbeResult {
        guard profile.source == .custom,
              !profile.allowedRelayURLs.isEmpty,
              (0.1 ... 30).contains(timeout),
              let secret = try? CmxIrohSecretKey(bytes: randomness.randomBytes(count: 32)) else {
            return .invalidProfile
        }
        let configuration = CmxIrohEndpointConfiguration(
            secretKey: secret,
            alpns: [Data("cmux/custom-relay-probe/1".utf8)],
            relayProfile: profile
        )
        let endpoint: any CmxIrohEndpoint
        do {
            endpoint = try await factory.bind(configuration: configuration)
        } catch {
            return .bindFailed
        }

        let result = await observe(
            endpoint: endpoint,
            allowedRelayURLs: profile.allowedRelayURLs,
            deadline: clock.now().addingTimeInterval(timeout)
        )
        await endpoint.close()
        switch result {
        case let .reachable(relayURL):
            return .reachable(relayURL: relayURL)
        case .closed:
            return .endpointClosed
        case .timedOut:
            return .timedOut
        }
    }

    private func observe(
        endpoint: any CmxIrohEndpoint,
        allowedRelayURLs: Set<String>,
        deadline: Date
    ) async -> Observation {
        if let relayURL = await selectedRelayURL(
            endpoint: endpoint,
            allowedRelayURLs: allowedRelayURLs
        ) {
            return .reachable(relayURL)
        }
        return await withTaskGroup(of: Observation.self) { group in
            group.addTask {
                let events = await endpoint.healthEvents()
                for await event in events {
                    guard !Task.isCancelled else { return .timedOut }
                    if event == .closedUnexpectedly { return .closed }
                    if let relayURL = await selectedRelayURL(
                        endpoint: endpoint,
                        allowedRelayURLs: allowedRelayURLs
                    ) {
                        return .reachable(relayURL)
                    }
                }
                return .closed
            }
            group.addTask { [clock] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return .timedOut
                }
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    private func selectedRelayURL(
        endpoint: any CmxIrohEndpoint,
        allowedRelayURLs: Set<String>
    ) async -> String? {
        let address = await endpoint.address()
        return address.pathHints.first {
            $0.kind == .relayURL && allowedRelayURLs.contains($0.value)
        }?.value
    }
}
