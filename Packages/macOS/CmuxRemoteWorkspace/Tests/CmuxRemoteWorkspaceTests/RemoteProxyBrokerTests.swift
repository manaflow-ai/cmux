import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// Scripted tunnel: records calls, can be told to fail `start()`, and
/// reports canned PTY results.
final class FakeProxyTunnel: RemoteProxyTunneling, @unchecked Sendable {
    struct PTYCall: Equatable {
        let name: String
        let arguments: [String]
    }

    let remotePath: String
    let localPort: Int
    private let startError: NSError?
    let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _ptyCalls: [PTYCall] = []
    var ptyLifecycleRegistry = RemotePTYLifecycleRegistry()
    var lifecycleEndCallbacks: [RemotePTYLifecycleKey: @Sendable () -> Void] = [:]

    init(remotePath: String, localPort: Int, startError: NSError?) {
        self.remotePath = remotePath
        self.localPort = localPort
        self.startError = startError
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCount
    }

    var ptyCalls: [PTYCall] {
        lock.lock()
        defer { lock.unlock() }
        return _ptyCalls
    }

    func start() throws {
        lock.lock()
        _startCount += 1
        lock.unlock()
        if let startError {
            throw startError
        }
    }

    func stop() {
        lock.lock()
        _stopCount += 1
        ptyLifecycleRegistry.removeAll()
        lifecycleEndCallbacks.removeAll()
        lock.unlock()
    }

    func stopPreservingPTYLifecycle() -> RemotePTYLifecycleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        _stopCount += 1
        lifecycleEndCallbacks.removeAll()
        return RemotePTYLifecycleSnapshot(registry: ptyLifecycleRegistry)
    }

    func restorePTYLifecycle(_ snapshot: RemotePTYLifecycleSnapshot) {
        lock.lock()
        ptyLifecycleRegistry = snapshot.registry
        lock.unlock()
    }

    func listPTY() throws -> [[String: Any]] {
        record("listPTY", [])
        return [["session_id": "s-1"]]
    }

    func closePTY(sessionID: String, deadline: DispatchTime) throws {
        record("closePTY", [sessionID])
        lock.lock()
        let previous = ptyLifecycleRegistry.requestIntentionalClose(sessionID: sessionID)
        ptyLifecycleRegistry.completeIntentionalClose(previous)
        lock.unlock()
    }

    func resizePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        record("resizePTY", [sessionID, attachmentID, attachmentToken, String(cols), String(rows)])
    }

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        record("detachPTY", [sessionID, attachmentID, attachmentToken])
    }

    func startPTYBridge(
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        onLifecycleEnded: @escaping @Sendable () -> Void
    ) throws -> RemotePTYBridgeServer.Endpoint {
        record("startPTYBridge", [sessionID, lifecycleID, attachmentID, command ?? "", String(requireExisting)])
        let key = RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
        let bridgeID = UUID()
        lock.lock()
        defer { lock.unlock() }
        try ptyLifecycleRegistry.registerBridge(key: key, attachmentID: attachmentID, bridgeID: bridgeID)
        ptyLifecycleRegistry.bridgeStopped(key: key, bridgeID: bridgeID, disposition: .acceptedClient)
        lifecycleEndCallbacks[key] = onLifecycleEnded
        return RemotePTYBridgeServer.Endpoint(
            host: "127.0.0.1",
            port: 4242,
            token: "tok",
            sessionID: sessionID,
            lifecycleID: lifecycleID,
            attachmentID: attachmentID
        )
    }

    func record(_ name: String, _ arguments: [String]) {
        lock.lock()
        _ptyCalls.append(PTYCall(name: name, arguments: arguments))
        lock.unlock()
    }
}

/// Provider that hands out ``FakeProxyTunnel``s and records every request,
/// including the failure callback so tests can simulate a running tunnel
/// dying.
final class FakeTunnelProvider: RemoteProxyTunnelProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _tunnels: [FakeProxyTunnel] = []
    private var _onFatalErrors: [@Sendable (String) -> Void] = []
    private var _failNextStarts = 0

    var tunnels: [FakeProxyTunnel] {
        lock.lock()
        defer { lock.unlock() }
        return _tunnels
    }

    /// The fatal-error callback paired with tunnel `index`.
    func fatalErrorCallback(at index: Int) -> (@Sendable (String) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard _onFatalErrors.indices.contains(index) else { return nil }
        return _onFatalErrors[index]
    }

    /// Makes the next `count` created tunnels throw from `start()`.
    func failNextStarts(_ count: Int) {
        lock.lock()
        _failNextStarts = count
        lock.unlock()
    }

    func makeTunnel(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping @Sendable (String) -> Void
    ) -> any RemoteProxyTunneling {
        lock.lock()
        defer { lock.unlock() }
        var startError: NSError?
        if _failNextStarts > 0 {
            _failNextStarts -= 1
            startError = NSError(domain: "test.tunnel", code: 99, userInfo: [
                NSLocalizedDescriptionKey: "scripted start failure",
            ])
        }
        let tunnel = FakeProxyTunnel(remotePath: remotePath, localPort: localPort, startError: startError)
        _tunnels.append(tunnel)
        _onFatalErrors.append(onFatalError)
        return tunnel
    }
}

/// Manual clock: parks every sleep until the test resumes it, recording the
/// requested delays so backoff escalation is assertable with virtual time.
final class ManualRetryClock: RemoteProxyRetryClock, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private var _requestedDelays: [Int] = []

    var requestedDelays: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedDelays
    }

    func sleep(forMilliseconds milliseconds: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            _requestedDelays.append(milliseconds)
            pending.append(continuation)
            lock.unlock()
        }
    }

    /// Waits (bounded) for `count` total sleeps to have been requested.
    @discardableResult
    func waitForSleeps(_ count: Int, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let reached = _requestedDelays.count >= count
            lock.unlock()
            if reached { return true }
            usleep(10_000)
        }
        return false
    }

    /// Resumes the oldest parked sleep (the timer "fires").
    func fireOldestSleep() {
        lock.lock()
        let continuation = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        continuation?.resume()
    }
}

/// Thread-safe recorder for subscriber updates.
private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [RemoteProxyBrokerUpdate] = []

    var updates: [RemoteProxyBrokerUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return _updates
    }

    func record(_ update: RemoteProxyBrokerUpdate) {
        lock.lock()
        _updates.append(update)
        lock.unlock()
    }

    /// Waits (bounded) until `predicate` holds over the updates seen so far.
    @discardableResult
    func wait(timeout: TimeInterval = 5.0, _ predicate: ([RemoteProxyBrokerUpdate]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(updates) { return true }
            usleep(10_000)
        }
        return false
    }
}

@Suite("RemoteProxyBroker", .serialized)
struct RemoteProxyBrokerTests {
    private func makeConfiguration(destination: String = "test@example.invalid", localProxyPort: Int? = nil) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination,
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: localProxyPort,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
    }

    @Test("acquire starts one tunnel and delivers .connecting then .ready")
    func acquireStartsTunnel() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let recorder = UpdateRecorder()

        let lease = broker.acquire(configuration: makeConfiguration(), remotePath: "/usr/local/bin/cmuxd-remote") {
            recorder.record($0)
        }
        defer { lease.release() }

        let updates = recorder.updates
        #expect(updates.count == 2)
        #expect(updates.first == .connecting)
        let tunnel = try #require(provider.tunnels.first)
        #expect(tunnel.startCount == 1)
        #expect(tunnel.remotePath == "/usr/local/bin/cmuxd-remote")
        #expect(updates.last == .ready(BrowserProxyEndpoint(host: "127.0.0.1", port: tunnel.localPort)))
    }

    @Test("a second subscriber on the same transport shares the tunnel and gets .ready immediately")
    func secondSubscriberSharesTunnel() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let first = UpdateRecorder()
        let second = UpdateRecorder()

        let leaseA = broker.acquire(configuration: makeConfiguration(), remotePath: "/r/p") { first.record($0) }
        defer { leaseA.release() }
        let leaseB = broker.acquire(configuration: makeConfiguration(), remotePath: "/r/p") { second.record($0) }
        defer { leaseB.release() }

        #expect(provider.tunnels.count == 1)
        let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: try #require(provider.tunnels.first).localPort)
        #expect(second.updates == [.ready(endpoint)])
    }

    @Test("acquiring with a changed remotePath restarts the shared tunnel")
    func changedRemotePathRestarts() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let first = UpdateRecorder()

        let leaseA = broker.acquire(configuration: makeConfiguration(), remotePath: "/old/path") { first.record($0) }
        defer { leaseA.release() }
        let leaseB = broker.acquire(configuration: makeConfiguration(), remotePath: "/new/path") { _ in }
        defer { leaseB.release() }

        #expect(provider.tunnels.count == 2)
        #expect(try #require(provider.tunnels.first).stopCount == 1)
        #expect(try #require(provider.tunnels.last).remotePath == "/new/path")
        // The original subscriber saw the restart: ready, connecting, ready.
        #expect(first.wait { updates in
            updates.count == 4
        })
        let updates = first.updates
        #expect(updates[0] == .connecting)
        if case .ready = updates[1] {} else { Issue.record("expected .ready, got \(updates[1])") }
        #expect(updates[2] == .connecting)
        if case .ready = updates[3] {} else { Issue.record("expected .ready, got \(updates[3])") }
    }

    @Test("start failures publish errors with the legacy escalating retry suffixes and backoff delays")
    func startFailureBackoffEscalates() throws {
        let provider = FakeTunnelProvider()
        provider.failNextStarts(2)
        let clock = ManualRetryClock()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: clock)
        let recorder = UpdateRecorder()

        let lease = broker.acquire(configuration: makeConfiguration(), remotePath: "/r/p") { recorder.record($0) }
        defer { lease.release() }

        #expect(recorder.wait { updates in
            updates.contains { update in
                if case .error(let detail) = update {
                    return detail.hasPrefix("Failed to start local daemon proxy:") && detail.hasSuffix("(retry in 3s)")
                }
                return false
            }
        })
        #expect(clock.waitForSleeps(1))
        clock.fireOldestSleep()

        #expect(recorder.wait { updates in
            updates.contains { update in
                if case .error(let detail) = update { return detail.hasSuffix("(retry in 6s)") }
                return false
            }
        })
        #expect(clock.waitForSleeps(2))
        clock.fireOldestSleep()

        // Third attempt succeeds and resets to .ready.
        #expect(recorder.wait { updates in
            if case .ready = updates.last { return true }
            return false
        })
        #expect(clock.requestedDelays == [3000, 6000])
        #expect(provider.tunnels.count == 3)
    }

    @Test("releasing the last lease stops the tunnel; a parked restart wakeup is absorbed by the token guard")
    func releaseTearsDownAndAbsorbsStaleWakeup() throws {
        let provider = FakeTunnelProvider()
        provider.failNextStarts(1)
        let clock = ManualRetryClock()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: clock)

        let lease = broker.acquire(configuration: makeConfiguration(), remotePath: "/r/p") { _ in }
        #expect(clock.waitForSleeps(1))

        lease.release()
        // Resume the parked backoff after teardown: the stale wakeup must not
        // start a new tunnel.
        clock.fireOldestSleep()

        // The transport is gone: PTY calls now fail with the not-ready error.
        // `listPTY` bridges through `queue.sync`, which drains every prior
        // `queue.async` block on the broker's serial queue first: both the
        // `teardownEntryLocked` enqueued by `release()` and the
        // `restartDelayElapsed` enqueued by the resumed retry Task. After it
        // returns, the stale wakeup is guaranteed to have run (and been
        // absorbed by the token guard), so the tunnel count is stable.
        #expect(throws: (any Error).self) {
            try broker.listPTY(configuration: makeConfiguration())
        }
        #expect(provider.tunnels.count == 1)
    }

    @Test("releasing the last lease stops a running tunnel")
    func releaseStopsRunningTunnel() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())

        let lease = broker.acquire(configuration: makeConfiguration(), remotePath: "/r/p") { _ in }
        let tunnel = try #require(provider.tunnels.first)
        #expect(tunnel.stopCount == 0)
        lease.release()

        let deadline = Date().addingTimeInterval(5.0)
        while tunnel.stopCount == 0 && Date() < deadline { usleep(10_000) }
        #expect(tunnel.stopCount == 1)
    }

    @Test("a fatal tunnel failure restarts after the backoff with the failure detail published")
    func fatalFailureRestarts() throws {
        let provider = FakeTunnelProvider()
        let clock = ManualRetryClock()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: clock)
        let recorder = UpdateRecorder()

        let lease = broker.acquire(configuration: makeConfiguration(), remotePath: "/r/p") { recorder.record($0) }
        defer { lease.release() }
        let tunnel = try #require(provider.tunnels.first)
        let onFatalError = try #require(provider.fatalErrorCallback(at: 0))

        onFatalError("transport died")
        #expect(recorder.wait { updates in
            updates.contains { update in
                if case .error(let detail) = update { return detail == "transport died (retry in 3s)" }
                return false
            }
        })
        let stopDeadline = Date().addingTimeInterval(5.0)
        while tunnel.stopCount == 0 && Date() < stopDeadline { usleep(10_000) }
        #expect(tunnel.stopCount == 1)

        #expect(clock.waitForSleeps(1))
        clock.fireOldestSleep()
        #expect(recorder.wait { updates in
            if case .ready = updates.last { return true }
            return false
        })
        #expect(provider.tunnels.count == 2)
    }

    @Test("PTY operations forward to the ready tunnel and throw code 40 when none is ready")
    func ptyOperationsForwardOrThrow() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()

        do {
            _ = try broker.listPTY(configuration: configuration)
            Issue.record("expected not-ready error")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.pty")
            #expect(nsError.code == 40)
            #expect(nsError.localizedDescription == "remote daemon tunnel is not ready")
        }

        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }
        let tunnel = try #require(provider.tunnels.first)

        let sessions = try broker.listPTY(configuration: configuration)
        #expect(sessions.first?["session_id"] as? String == "s-1")
        let lifecycle = try broker.ptySessionLifecycle(configuration: configuration, sessionID: "s-8", lifecycleID: "life-8")
        try broker.acknowledgePTYLifecycle(configuration: configuration, sessionID: "s-8", lifecycleID: "life-8")
        try broker.closePTY(configuration: configuration, sessionID: "s-9", deadline: .distantFuture)
        try broker.resizePTY(configuration: configuration, sessionID: "s", attachmentID: "a", attachmentToken: "t", cols: 80, rows: 24)
        try broker.detachPTY(configuration: configuration, sessionID: "s", attachmentID: "a", attachmentToken: "t")
        let endpoint = try broker.startPTYBridge(configuration: configuration, sessionID: "s", lifecycleID: "life", attachmentID: "a", command: "top", requireExisting: true)
        #expect(endpoint.port == 4242)
        #expect(lifecycle == .active)

        #expect(tunnel.ptyCalls == [
            FakeProxyTunnel.PTYCall(name: "listPTY", arguments: []),
            FakeProxyTunnel.PTYCall(name: "ptySessionLifecycle", arguments: ["s-8", "life-8"]),
            FakeProxyTunnel.PTYCall(name: "acknowledgePTYLifecycle", arguments: ["s-8", "life-8"]),
            FakeProxyTunnel.PTYCall(name: "closePTY", arguments: ["s-9"]),
            FakeProxyTunnel.PTYCall(name: "resizePTY", arguments: ["s", "a", "t", "80", "24"]),
            FakeProxyTunnel.PTYCall(name: "detachPTY", arguments: ["s", "a", "t"]),
            FakeProxyTunnel.PTYCall(name: "startPTYBridge", arguments: ["s", "life", "a", "top", "true"]),
        ])
    }

}
