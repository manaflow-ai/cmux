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
    /// closed and reported as a failure. Returns as soon as the decision is
    /// made: losing attempts are cancelled in the background and any late
    /// transport is closed, so a carrier slow to honor cancellation never
    /// delays the winner.
    public func race(to peer: LinkPeer, betterThan threshold: Int? = nil) async throws -> any LinkTransport {
        let eligible = carriers.enumerated().filter { _, carrier in
            guard let threshold else { return true }
            return policy.bestRank(of: carrier) < threshold
        }
        guard !eligible.isEmpty else { throw LinkError.allCarriersFailed([]) }

        let (outcomes, sink) = AsyncStream<Outcome>.makeStream()
        var attempts: [Task<Void, Never>] = []
        var pending: [Int: Int] = [:]
        for (index, carrier) in eligible {
            pending[index] = policy.bestRank(of: carrier)
            attempts.append(Task {
                do {
                    let transport = try await carrier.connect(to: peer)
                    sink.yield(.connected(index, transport, await transport.path))
                } catch {
                    sink.yield(.failed(index, "\(carrier.kind): \(error)"))
                }
            })
        }
        let started = attempts
        Task {
            for attempt in started { await attempt.value }
            sink.finish()
        }
        var deadline: Task<Void, Never>?

        var best: (rank: Int, transport: any LinkTransport)?
        var failures: [String] = []
        var iterator = outcomes.makeAsyncIterator()
        var decided = false
        await withTaskCancellationHandler {
            while !decided, let outcome = await iterator.next() {
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
                if Task.isCancelled { decided = true }
                guard let current = best else {
                    if pending.isEmpty { decided = true }
                    continue
                }
                if !pending.values.contains(where: { $0 < current.rank }) {
                    decided = true
                } else if deadline == nil {
                    let window = policy.preferenceWindow
                    deadline = Task { [clock] in
                        try? await clock.sleep(for: window)
                        sink.yield(.deadline)
                    }
                }
            }
        } onCancel: {
            sink.finish()
        }
        let lateDeadline = deadline
        for attempt in attempts { attempt.cancel() }
        lateDeadline?.cancel()
        // Close anything that still connects after the decision.
        Task {
            while let late = await iterator.next() {
                if case let .connected(_, transport, _) = late { await transport.close() }
            }
        }
        if Task.isCancelled {
            if let best { await best.transport.close() }
            throw CancellationError()
        }
        guard let winner = best else { throw LinkError.allCarriersFailed(failures) }
        return winner.transport
    }
}
