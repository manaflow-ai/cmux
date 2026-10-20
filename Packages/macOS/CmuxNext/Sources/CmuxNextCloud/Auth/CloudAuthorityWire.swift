package import Foundation

/// One owner wire: bounded frame reads stay independent of authority HTTP checks and the lease deadline.
package actor CloudAuthorityWire {
    package enum State: Sendable, Equatable { case ready, lost }
    nonisolated package let events: AsyncStream<State>
    package typealias Connect = @Sendable (CloudAuthorityWireLease) async throws -> any CloudAuthorityWireSocket
    private let lease: CloudAuthorityWireLease
    private let connect: Connect
    private let recheck: @Sendable () async throws -> Void
    private let states: AsyncStream<State>.Continuation
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activity = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let firstReady = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var started = false
    private var welcomed = false
    private var snapshot = false
    private var ready = false
    private var lost = false

    package init(lease: CloudAuthorityWireLease, connect: @escaping Connect,
                 recheck: @escaping @Sendable () async throws -> Void,
                 now: @escaping @Sendable () -> Date = Date.init,
                 // wakeup-allow: injected, cancellable handshake and credential-expiry deadlines; no polling.
                 sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        self.lease = lease; self.connect = connect; self.recheck = recheck
        let changes = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = changes.stream; states = changes.continuation
        self.now = now; self.sleep = sleep
    }

    /// The caller owns this task and joins it on replacement, including any HTTP check still draining.
    package func run() async throws {
        guard !started else { throw CloudAuthorityWireLease.Failure.closed }
        started = true
        defer { activity.continuation.finish(); firstReady.continuation.finish(); states.finish() }
        do {
            guard lease.expiresAt > now() else { throw CloudAuthorityWireLease.Failure.expired }
            let socket = try await connect(lease)
            do {
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.guarded { try await self.read(socket) } }
                    group.addTask { try await self.guarded { try await self.verify() } }
                    group.addTask { try await self.guarded { try await self.deadline() } }
                    group.addTask { try await self.guarded { try await self.handshake() } }
                    // The handshake task ends normally once ready; all other work lasts until loss/cancellation.
                    do { for try await _ in group {} }
                    catch { group.cancelAll(); await socket.close(); throw error }
                    group.cancelAll()
                    await socket.close()
                    throw CloudAuthorityWireLease.Failure.closed
                }
            } catch {
                await socket.close()
                throw error
            }
        } catch {
            if !Task.isCancelled { fail() }
            throw error
        }
    }

    private func guarded(_ work: @Sendable () async throws -> Void) async throws {
        do { try await work() }
        catch {
            if !Task.isCancelled { fail() }
            throw error
        }
    }

    private func fail() {
        guard !lost else { return }
        lost = true
        // The parent consumes loss independently of HTTP drain; a queued ready cannot overtake it.
        states.yield(.lost)
        activity.continuation.finish()
    }

    private func read(_ socket: any CloudAuthorityWireSocket) async throws {
        // wakeup-allow: every iteration waits for an owner frame; cancellation closes the socket.
        while !Task.isCancelled {
            let data = try await socket.receive()
            guard data.count <= 8 << 20, let frame = try? JSONDecoder().decode(Header.self, from: data),
                  !frame.t.isEmpty, frame.t.utf8.count <= 64 else { throw CloudAuthorityWireLease.Failure.frame }
            if frame.t == "welcome" {
                guard !welcomed, frame.principal?.user == lease.user, frame.principal?.team == lease.team,
                      frame.principal?.install == lease.install, let streams = frame.streams,
                      streams.count <= 16, streams.contains(lease.stream) else { throw CloudAuthorityWireLease.Failure.identity }
                welcomed = true
                try await socket.send(Data(#"{"t":"subscribe","pending":[]}"#.utf8))
                continue
            }
            guard welcomed, frame.t != "error", frame.t != "reject",
                  frame.stream == nil || frame.stream == lease.stream else { throw CloudAuthorityWireLease.Failure.frame }
            if frame.t == "snapshot" || frame.t == "event" {
                guard frame.stream == lease.stream, let seq = frame.seq, seq <= 9_007_199_254_740_991,
                      frame.t == "snapshot" || snapshot else { throw CloudAuthorityWireLease.Failure.frame }
                if frame.t == "snapshot" { snapshot = true }
            }
            guard snapshot else { throw CloudAuthorityWireLease.Failure.frame }
            // Unknown ephemeral frames also cause a current-owner check; no generic event is silently trusted.
            activity.continuation.yield(())
        }
        throw CancellationError()
    }

    private func verify() async throws {
        for await _ in activity.stream {
            try Task.checkCancellation()
            try await recheck()
            try Task.checkCancellation()
            guard !lost else { throw CloudAuthorityWireLease.Failure.closed }
            guard lease.expiresAt > now() else { throw CloudAuthorityWireLease.Failure.expired }
            if !ready {
                ready = true
                firstReady.continuation.yield(())
                firstReady.continuation.finish()
                states.yield(.ready)
            }
        }
    }

    private func handshake() async throws {
        let stream = firstReady.stream, sleep = sleep
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CloudAuthorityWireLease.Failure.closed }
                try Task.checkCancellation()
            }
            group.addTask {
                // The initial subscription must become checked and ready within this genuine deadline.
                try await sleep(.seconds(15))
                try Task.checkCancellation()
                throw CloudAuthorityWireLease.Failure.handshake
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func deadline() async throws {
        let remaining = lease.expiresAt.timeIntervalSince(now())
        guard remaining > 0 else { throw CloudAuthorityWireLease.Failure.expired }
        // A credential expiry deadline, injected so tests advance it without polling or wall-clock sleeps.
        try await sleep(.seconds(remaining))
        try Task.checkCancellation()
        throw CloudAuthorityWireLease.Failure.expired
    }

    private struct Header: Decodable {
        let t: String; let stream: String?; let seq: UInt64?; let streams: [String]?; let principal: Principal?
        struct Principal: Decodable { let user: String?; let team: String?; let install: String? }
    }
}
