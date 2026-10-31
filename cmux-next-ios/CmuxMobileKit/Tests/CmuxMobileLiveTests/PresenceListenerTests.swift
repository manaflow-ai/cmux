import Foundation
import Testing
@testable import CmuxMobileLive

/// Virtual time lets liveness deadlines run without network or wall-clock sleeps.
private final class PresenceTestClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration
    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []
    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var pendingCount: Int { lock.withLock { sleepers.count } }
    var pendingDelays: [Duration] {
        lock.withLock { sleepers.values.map { $0.deadline - instant }.sorted() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Bool? = lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled { return false }
                    if deadline <= instant { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let immediate {
                    if immediate { continuation.resume() }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            }
        } onCancel: {
            let sleeper = self.lock.withLock {
                self.cancelled.insert(id)
                return self.sleepers.removeValue(forKey: id)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            instant += duration
            let ids = sleepers.filter { $0.value.deadline <= instant }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

@MainActor
private final class PresenceTestSocket: PresenceSocket {
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?
    private var pongs: [@Sendable (Error?) -> Void] = []
    var state: URLSessionTask.State = .suspended
    var resumes = 0
    var cancellations = 0
    var pingCount = 0
    var keepsReceiveAfterCancel = false
    var waitingForReceive: Bool { receiver != nil }

    func resume() { resumes += 1; state = .running }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pingCount += 1
        pongs.append(pongReceiveHandler)
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancellations += 1
        state = .canceling
        if !keepsReceiveAfterCancel { failReceive(CancellationError()) }
    }
    func send(_ text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: message)
        } else { messages.append(message) }
    }
    func hello(online: Bool = true) {
        send(#"{"type":"hello","you":"phone","macs":[{"deviceId":"mac","name":"Mac","online":\#(online)}]}"#)
    }
    func pong(_ error: (any Error)? = nil) {
        guard !pongs.isEmpty else { Issue.record("No pending ping"); return }
        pongs.removeFirst()(error)
    }
    func failReceive(_ error: any Error) {
        let pending = receiver
        receiver = nil
        pending?.resume(throwing: error)
    }
}

@MainActor
private final class PresenceTestRig {
    let clock = PresenceTestClock()
    var sockets: [PresenceTestSocket] = []
    var events: [String] = []
    var refreshes = 0
    var request: (@MainActor () async throws -> URLRequest)?
    var refresh: (@MainActor () async throws -> [LiveAPI.Mac])?
    var configureSocket: (@MainActor (PresenceTestSocket) -> Void)?
    lazy var listener = PresenceListener(
        clock: clock,
        signalRequest: { [unowned self] in
            if let request { return try await request() }
            return URLRequest(url: URL(string: "https://presence.invalid/signal")!)
        },
        fetchMacs: { [unowned self] in
            refreshes += 1
            if let refresh { return try await refresh() }
            return [LiveAPI.Mac(deviceId: "fresh", name: "Fresh", online: true)]
        },
        makeSocket: { [unowned self] _ in
            let socket = PresenceTestSocket()
            configureSocket?(socket)
            sockets.append(socket)
            return socket
        },
        onUpdate: { [unowned self] update in
            switch update {
            case .connected(let connected): events.append("connected:\(connected)")
            case .snapshot(let macs): events.append("snapshot:\(macs.map(\.deviceId).joined(separator: ","))")
            case .mac(let mac): events.append("mac:\(mac.deviceId)")
            }
        }
    )

    func finish() async {
        listener.stop()
        for socket in sockets { socket.failReceive(CancellationError()) }
        await settle { self.clock.pendingCount == 0 }
    }
}

/// Bounded executor turns only; no wall-clock polling or live network is needed.
/// Readiness predicates name the actual deadline, not just a timer count: the
/// ping timeout and the next ping interval both have exactly one pending timer.
@MainActor
private func settle(until condition: (() -> Bool)? = nil) async {
    guard let condition else {
        for _ in 0..<200 { await Task.yield() }
        return
    }
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    #expect(condition(), "Presence operation did not reach its expected state")
}

@MainActor
@Suite struct PresenceListenerTests {
    @Test func missingPongClosesHalfOpenSocketAndRefreshesPresence() async {
        let rig = PresenceTestRig()
        rig.listener.start()
        await settle { rig.sockets.first?.pingCount == 1 && rig.clock.pendingDelays == [PresenceListener.pingTimeout, PresenceListener.helloTimeout] }
        guard let socket = rig.sockets.first else { Issue.record("No socket"); return }
        socket.hello(online: false)
        await settle { rig.events.contains("connected:true") }
        #expect(socket.state == .running)
        rig.clock.advance(by: PresenceListener.pingTimeout)
        await settle { rig.events.last == "snapshot:fresh" }
        #expect(socket.cancellations == 1)
        #expect(rig.events.contains("connected:false"))
        #expect(rig.events.last == "snapshot:fresh")
        #expect(rig.refreshes == 1)
        await settle { rig.clock.pendingDelays == [.seconds(2)] }
        rig.clock.advance(by: .seconds(2))
        await settle { rig.sockets.count == 2 }
        #expect(rig.sockets.count == 2)
        await rig.finish()
    }

    @Test func kickImmediatelyReplacesRunningSocketAndStartIsIdempotent() async {
        let rig = PresenceTestRig()
        rig.listener.start()
        rig.listener.start()
        await settle { rig.sockets.count == 1 }
        guard let old = rig.sockets.first else { Issue.record("No socket"); return }
        #expect(old.state == .running)
        rig.listener.kick()
        await settle { rig.sockets.count == 2 }
        #expect(old.cancellations == 1)
        #expect(rig.sockets.count == 2)
        #expect(rig.sockets.last?.resumes == 1)
        await rig.finish()
    }

    @Test func kickBypassesReconnectBackoff() async {
        let rig = PresenceTestRig()
        rig.listener.start()
        await settle { rig.sockets.first?.waitingForReceive == true }
        rig.sockets.first?.failReceive(URLError(.networkConnectionLost))
        await settle { rig.refreshes == 1 && rig.clock.pendingDelays == [.seconds(2)] }
        #expect(rig.sockets.count == 1)
        rig.listener.kick()
        await settle { rig.sockets.count == 2 }
        #expect(rig.sockets.count == 2)
        await rig.finish()
        #expect(rig.clock.pendingCount == 0)
    }

    @Test func healthyPongsRepeatWithoutReplacingSocket() async {
        let rig = PresenceTestRig()
        rig.listener.start()
        await settle { rig.sockets.first?.pingCount == 1 }
        guard let socket = rig.sockets.first else { Issue.record("No socket"); return }
        socket.hello()
        socket.pong()
        await settle { rig.clock.pendingDelays == [PresenceListener.pingInterval] }
        for expectedPings in 2...4 {
            rig.clock.advance(by: PresenceListener.pingInterval)
            await settle { socket.pingCount == expectedPings }
            #expect(socket.pingCount == expectedPings)
            socket.pong()
            await settle { rig.clock.pendingDelays == [PresenceListener.pingInterval] }
        }
        #expect(rig.sockets.count == 1)
        #expect(socket.cancellations == 0)
        #expect(rig.refreshes == 0)
        await rig.finish()
    }

    @Test func pongWithoutHelloStillHitsHelloDeadline() async {
        let rig = PresenceTestRig()
        rig.listener.start()
        await settle { rig.sockets.first?.pingCount == 1 && rig.clock.pendingDelays == [PresenceListener.pingTimeout, PresenceListener.helloTimeout] }
        guard let socket = rig.sockets.first else { Issue.record("No socket"); return }
        socket.pong()
        await settle { rig.clock.pendingDelays == [PresenceListener.helloTimeout, PresenceListener.pingInterval] }
        rig.clock.advance(by: PresenceListener.helloTimeout)
        await settle { rig.refreshes == 1 }
        #expect(socket.cancellations == 1)
        #expect(!rig.events.contains("connected:true"))
        #expect(rig.refreshes == 1)
        await rig.finish()
    }

    @Test func stalePongAndReceiveCannotAffectReplacement() async {
        let rig = PresenceTestRig()
        rig.configureSocket = { $0.keepsReceiveAfterCancel = true }
        rig.listener.start()
        await settle { rig.sockets.first?.pingCount == 1 && rig.sockets.first?.waitingForReceive == true }
        guard let old = rig.sockets.first else { Issue.record("No socket"); return }
        rig.listener.kick()
        await settle { rig.sockets.count == 2 }
        guard rig.sockets.count == 2 else { await rig.finish(); return }
        let replacement = rig.sockets[1]
        let before = rig.events
        old.pong(URLError(.networkConnectionLost))
        old.hello(online: false)
        await settle()
        #expect(rig.events == before)
        #expect(replacement.cancellations == 0)
        #expect(rig.refreshes == 0)
        await rig.finish()
    }

    @Test func staleSignalRequestCannotInstallSocketAfterKick() async {
        let rig = PresenceTestRig()
        var held: CheckedContinuation<URLRequest, Never>?
        rig.request = {
            await withCheckedContinuation { held = $0 }
        }
        rig.listener.start()
        await settle { held != nil }
        rig.request = nil
        rig.listener.kick()
        await settle { rig.sockets.count == 1 }
        held?.resume(returning: URLRequest(url: URL(string: "https://presence.invalid/old")!))
        held = nil
        await settle()
        #expect(rig.sockets.count == 1)
        #expect(rig.sockets.first?.cancellations == 0)
        await rig.finish()
    }

    @Test func staleHTTPRefreshCannotOverwriteReplacementSnapshot() async {
        let rig = PresenceTestRig()
        var held: CheckedContinuation<[LiveAPI.Mac], Never>?
        rig.refresh = { await withCheckedContinuation { held = $0 } }
        rig.listener.start()
        await settle { rig.sockets.first?.waitingForReceive == true }
        rig.sockets.first?.failReceive(URLError(.networkConnectionLost))
        await settle { held != nil }
        rig.listener.kick()
        await settle { rig.sockets.count == 2 }
        rig.sockets.last?.hello()
        await settle { rig.events.contains("snapshot:mac") }
        let before = rig.events
        held?.resume(returning: [LiveAPI.Mac(deviceId: "stale", name: "Stale", online: false)])
        held = nil
        await settle()
        #expect(rig.events == before)
        #expect(rig.sockets.last?.cancellations == 0)
        await rig.finish()
    }

    @Test func stopCancelsTimersAndIgnoresLateCallbacks() async {
        let rig = PresenceTestRig()
        rig.configureSocket = { $0.keepsReceiveAfterCancel = true }
        rig.listener.start()
        await settle { rig.sockets.first?.pingCount == 1 && rig.clock.pendingDelays == [PresenceListener.pingTimeout, PresenceListener.helloTimeout] }
        guard let socket = rig.sockets.first else { Issue.record("No socket"); return }
        rig.listener.stop()
        await settle { rig.clock.pendingCount == 0 }
        let before = rig.events
        socket.pong(URLError(.networkConnectionLost))
        socket.hello()
        rig.clock.advance(by: .seconds(100))
        await settle()
        #expect(rig.events == before)
        #expect(rig.sockets.count == 1)
        #expect(socket.cancellations == 1)
        #expect(rig.clock.pendingCount == 0)
        #expect(rig.refreshes == 0)
        await rig.finish()
    }
}
