package import Foundation

/// Owns checked user/team subscriptions and hands off renewed credentials before retiring the old pair.
package actor CloudAuthorityObservation {
    package typealias State = CloudAuthorityWire.State
    nonisolated package let events: AsyncStream<State>
    nonisolated package let scopeID: String
    private let team: String
    private let leases: @Sendable () async throws -> [CloudAuthorityWireLease]
    private let recheck: @Sendable () async throws -> Void
    private let connect: CloudAuthorityWire.Connect
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let states: AsyncStream<State>.Continuation
    private var started = false
    private var stopped = false
    private var announced = false
    private var active: UUID?
    private var candidate: UUID?
    private var pairs: [UUID: Pair] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var renewal: Task<Void, Never>?

    package init(scopeID: String, team: String,
                 leases: @escaping @Sendable () async throws -> [CloudAuthorityWireLease],
                 recheck: @escaping @Sendable () async throws -> Void, connect: @escaping CloudAuthorityWire.Connect,
                 now: @escaping @Sendable () -> Date = Date.init,
                 // wakeup-allow: one cancellable credential-renewal deadline, never readiness polling.
                 sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        self.scopeID = scopeID; self.team = team; self.leases = leases; self.recheck = recheck
        self.connect = connect; self.now = now; self.sleep = sleep
        let changes = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = changes.stream; states = changes.continuation
    }

    /// The caller owns and joins this initial load; readiness arrives only after both subscriptions are checked.
    package func start() async throws {
        guard !started, !stopped else { throw CloudAuthorityWireLease.Failure.closed }
        started = true
        do {
            let credentials = try await leases()
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            try await recheck()
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            let id = try makePair(credentials)
            candidate = id
            runPair(id)
        } catch {
            if !Task.isCancelled, !stopped { lose() }
            throw error
        }
    }

    /// Ends every owned reader and timer, including old pairs whose HTTP work is still draining.
    package func stop() async {
        stopped = true; active = nil; candidate = nil
        states.yield(.lost)
        states.finish()
        let renewing = renewal, draining = Array(jobs.values)
        renewal = nil
        renewing?.cancel()
        for job in draining { job.cancel() }
        await renewing?.value
        for job in draining { await job.value }
        pairs.removeAll(); jobs.removeAll()
    }

    private func makePair(_ credentials: [CloudAuthorityWireLease]) throws -> UUID {
        guard credentials.count == 2,
              let user = credentials.first(where: { $0.owner == .user }),
              let selected = credentials.first(where: { $0.owner == .team }),
              selected.team == team, user.user == selected.user, user.install == selected.install else {
            throw CloudAuthorityWireLease.Failure.identity
        }
        let expiresAt = min(user.expiresAt, selected.expiresAt)
        guard expiresAt > now(), active.flatMap({ pairs[$0]?.expiresAt }).map({ expiresAt > $0 }) ?? true else {
            throw CloudAuthorityWireLease.Failure.expired
        }
        let id = UUID()
        let channels = credentials.map { lease in
            (lease.owner, CloudAuthorityWire(lease: lease, connect: connect, recheck: recheck, now: now, sleep: sleep))
        }
        pairs[id] = Pair(wires: Dictionary(uniqueKeysWithValues: channels), expiresAt: expiresAt)
        return id
    }

    private func runPair(_ id: UUID) {
        guard let pair = pairs[id] else { return }
        let channels = pair.wires
        // task-owner: jobs; stop joins every pair, including a retiring pair with a held HTTP check.
        jobs[id] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (owner, wire) in channels {
                    group.addTask { do { try await wire.run() } catch {} }
                    group.addTask { [weak self] in
                        for await state in wire.events {
                            guard !Task.isCancelled else { return }
                            await self?.receive(state, owner: owner, pair: id)
                        }
                    }
                }
                await group.waitForAll()
            }
            await self?.finished(id)
        }
    }

    private func receive(_ state: State, owner: CloudAuthorityWireLease.Owner, pair id: UUID) async {
        guard !stopped, id == active || id == candidate else { return }
        if state == .lost { lose(); return }
        pairs[id]?.ready.insert(owner)
        guard id == candidate, pairs[id]?.ready == Set([.user, .team]), pairs[id]?.checking == false else { return }
        pairs[id]?.checking = true
        do { try await recheck() }
        catch { if !stopped { lose() }; return }
        guard !stopped, candidate == id, let expires = pairs[id]?.expiresAt else { return }
        guard expires > now() else { lose(); return }
        let old = active
        active = id; candidate = nil
        if !announced { announced = true; states.yield(.ready) }
        scheduleRenewal(expires)
        // A checked replacement owns observation now. The old pair's subsequent close cannot retire it.
        if let old { jobs[old]?.cancel() }
    }

    private func scheduleRenewal(_ expiresAt: Date) {
        renewal?.cancel()
        let delay = max(0, expiresAt.timeIntervalSince(now()) - 50), sleep = sleep
        // task-owner: renewal; stop cancels and joins its deadline and any scoped lease load.
        renewal = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
                try Task.checkCancellation()
                await self?.renew()
            } catch {}
        }
    }

    private func renew() async {
        guard !stopped, candidate == nil, let original = active else { return }
        do {
            let credentials = try await leases()
            try Task.checkCancellation()
            guard !stopped, active == original, candidate == nil else { return }
            try await recheck()
            try Task.checkCancellation()
            guard !stopped, active == original, candidate == nil else { return }
            let id = try makePair(credentials)
            candidate = id
            runPair(id)
        } catch {
            if !Task.isCancelled, !stopped { lose() }
        }
    }

    private func lose() {
        guard !stopped else { return }
        stopped = true; active = nil; candidate = nil
        // Consumers fence immediately; owned HTTP and socket work is joined separately by stop().
        states.yield(.lost); states.finish()
        renewal?.cancel()
        for job in jobs.values { job.cancel() }
    }

    private func finished(_ id: UUID) {
        jobs[id] = nil; pairs[id] = nil
        if !stopped, id == active || id == candidate { lose() }
    }

    private struct Pair {
        let wires: [CloudAuthorityWireLease.Owner: CloudAuthorityWire]
        let expiresAt: Date
        var ready: Set<CloudAuthorityWireLease.Owner> = []
        var checking = false
    }
}
