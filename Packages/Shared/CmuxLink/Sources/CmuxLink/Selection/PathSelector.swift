/// Races carriers in policy order (a3-link.md section 6). Every eligible
/// carrier starts at once; the first success wins at once when no pending
/// carrier could produce a better path, otherwise the selector waits up to
/// `preferenceWindow` for one. Losing transports are closed.
public struct PathSelector: Sendable {
    public let carriers: [any LinkCarrier]
    public let policy: PathPolicy
    private let clock: LinkClock

    public init(carriers: [any LinkCarrier], policy: PathPolicy = PathPolicy(), clock: LinkClock = .continuous) {
        self.carriers = carriers
        self.policy = policy
        self.clock = clock
    }

    /// The best rank any configured carrier could produce.
    public var bestReachableRank: Int {
        carriers.map(policy.bestRank(of:)).min() ?? policy.order.count
    }

    private enum Outcome: Sendable {
        case connected(Int, any LinkTransport, LinkPath)
        case failed(Int, String)
        case deadline
    }

    /// Connects through the best carrier. With `betterThan`, only carriers
    /// that could beat that rank run, and a result that does not beat it is
    /// closed and reported as a failure.
    public func race(to peer: LinkPeer, betterThan threshold: Int? = nil) async throws -> any LinkTransport {
        let eligible = carriers.enumerated().filter { _, carrier in
            guard let threshold else { return true }
            return policy.bestRank(of: carrier) < threshold
        }
        guard !eligible.isEmpty else { throw LinkError.allCarriersFailed([]) }

        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            var pending: [Int: Int] = [:]
            for (index, carrier) in eligible {
                pending[index] = policy.bestRank(of: carrier)
                group.addTask {
                    do {
                        let transport = try await carrier.connect(to: peer)
                        return .connected(index, transport, await transport.path)
                    } catch {
                        return .failed(index, "\(carrier.kind): \(error)")
                    }
                }
            }

            var best: (rank: Int, transport: any LinkTransport)?
            var failures: [String] = []
            var deadlineStarted = false
            var decided = false

            while !decided, let outcome = try await group.next() {
                switch outcome {
                case let .connected(index, transport, path):
                    pending[index] = nil
                    let rank = policy.rank(of: path.kind)
                    if let threshold, rank >= threshold {
                        await transport.close()
                        failures.append("\(path.carrier): path \(path.kind) not better")
                    } else if let current = best, current.rank <= rank {
                        await transport.close()
                    } else {
                        if let current = best { await current.transport.close() }
                        best = (rank, transport)
                    }
                case let .failed(index, message):
                    pending[index] = nil
                    failures.append(message)
                case .deadline:
                    decided = best != nil
                }
                guard let current = best else {
                    if pending.isEmpty { decided = true }
                    continue
                }
                let couldBeat = pending.values.contains { $0 < current.rank }
                if !couldBeat {
                    decided = true
                } else if !deadlineStarted {
                    deadlineStarted = true
                    let window = policy.preferenceWindow
                    group.addTask { [clock] in
                        try? await clock.sleep(for: window)
                        return .deadline
                    }
                }
            }

            group.cancelAll()
            // Close anything that still connects after the decision.
            while let late = try await group.next() {
                if case let .connected(_, transport, _) = late { await transport.close() }
            }
            guard let winner = best else { throw LinkError.allCarriersFailed(failures) }
            return winner.transport
        }
    }
}
