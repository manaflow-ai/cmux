import CmuxLink

/// Runs the conformance suite on the in-process loopback carrier, optionally
/// through simulated latency, jitter and loss.
public final class LoopbackHarness: ConformanceHarness {
    public let name: String
    private let conditions: NetworkConditions?
    private let path: PathKind
    private let state = HarnessNetworkBox()

    public init(name: String = "loopback", conditions: NetworkConditions? = nil, path: PathKind = .direct) {
        self.name = name
        self.conditions = conditions
        self.path = path
    }

    public func makeEndpoints() async throws -> ConformanceEndpoints {
        let network = LoopbackNetwork(conditions: conditions)
        await state.set(network)
        return ConformanceEndpoints(
            carriers: [network.carrier(kind: .direct, path: path, candidatePaths: PathKind.allCases)],
            acceptor: network.acceptor
        )
    }

    public func dropTransports() async -> Bool {
        guard let network = await state.network else { return false }
        await network.dropAll()
        return true
    }

    public func changePath(to kind: PathKind) async -> Bool {
        guard let network = await state.network else { return false }
        await network.changePath(to: kind)
        return true
    }

    public func roam(to kind: PathKind) async -> Bool {
        guard let network = await state.network else { return false }
        await network.roam(to: kind)
        return true
    }

    public func throttle(bytesPerSecond: Int?) async -> Bool {
        guard let network = await state.network else { return false }
        var next = conditions ?? NetworkConditions()
        next.bytesPerSecond = bytesPerSecond
        await network.setConditions(bytesPerSecond == nil ? conditions : next)
        return true
    }

    public func tearDown() async {
        await state.set(nil)
    }
}
