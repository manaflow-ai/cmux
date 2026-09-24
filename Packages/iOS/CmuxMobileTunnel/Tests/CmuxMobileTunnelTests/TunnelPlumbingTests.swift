import Darwin
import Foundation
import Testing
@testable import CmuxMobileTunnel

@Suite(.serialized) struct TunnelPortForwardTests {
    @Test(.timeLimit(.minutes(1))) func forwardsEachConnectionToTheTargetAtTheExit() async throws {
        let backend = ScriptedBackend()
        let forward = try await TunnelPortForward.start(backend: backend, targetHost: "::1", targetPort: 5173)
        let port = forward.localPort
        let echoed = try await Task.detached { () throws -> [UInt8] in
            let fd = try RawClient.connect(port: port)
            defer { close(fd) }
            RawClient.send(fd, Array("hello".utf8))
            shutdown(fd, SHUT_WR)
            return RawClient.receiveAll(fd)
        }.value
        #expect(echoed == Array("hello<eof>".utf8))
        #expect(backend.opens.first?.0 == "::1")
        #expect(backend.opens.first?.1 == 5173)
        await forward.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aFailedOpenClosesTheBrowserConnection() async throws {
        let backend = ScriptedBackend()
        backend.failure = TunnelOpenError.connectionRefused
        let forward = try await TunnelPortForward.start(backend: backend, targetHost: "127.0.0.1", targetPort: 1)
        let port = forward.localPort
        let rest = try await Task.detached { () throws -> [UInt8] in
            let fd = try RawClient.connect(port: port)
            defer { close(fd) }
            return RawClient.receiveAll(fd)
        }.value
        #expect(rest.isEmpty)
        await forward.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aTakenPortFailsToBind() async throws {
        let backend = ScriptedBackend()
        let first = try await TunnelPortForward.start(backend: backend, targetHost: "127.0.0.1", targetPort: 1)
        await #expect(throws: (any Error).self) {
            _ = try await TunnelPortForward.start(
                backend: backend, targetHost: "127.0.0.1", targetPort: 1, localPort: first.localPort
            )
        }
        await first.stop()
    }
}

@MainActor
@Suite struct LoopbackPortRegistryTests {
    @Test func anotherOwnersForwardIsEvictedButAProxyIsNot() async {
        let registry = LoopbackPortRegistry()
        var stopped: [Int] = []
        registry.register(port: 3000, owner: "ssh:a") { stopped.append(3000) }
        registry.register(port: 5000, owner: "mac:b", pinned: true) { stopped.append(5000) }

        #expect(await registry.evict(port: 3000, for: "mac:b"))
        #expect(stopped == [3000])
        #expect(registry.entry(for: 3000) == nil)

        #expect(await registry.evict(port: 5000, for: "ssh:a") == false)
        #expect(registry.entry(for: 5000)?.owner == "mac:b")
        #expect(registry.pinnedPorts == [5000])

        // Its own entry and a free port are fine to use.
        #expect(await registry.evict(port: 5000, for: "mac:b"))
        #expect(await registry.evict(port: 6000, for: "mac:b"))
        #expect(stopped == [3000])
    }

    @Test func releaseOnlyForgetsTheOwnersEntry() {
        let registry = LoopbackPortRegistry()
        registry.register(port: 3000, owner: "ssh:a") {}
        registry.release(port: 3000, owner: "mac:b")
        #expect(registry.entry(for: 3000) != nil)
        registry.release(port: 3000, owner: "ssh:a")
        #expect(registry.entry(for: 3000) == nil)
        #expect(registry.ports(ownedBy: "ssh:a").isEmpty)
    }
}

@Suite struct TunnelRoutingTests {
    @Test func loopbackHostsAreRecognized() {
        for host in ["localhost", "LOCALHOST.", "app.localhost", "127.0.0.1", "127.9.8.7", "::1", "[::1]",
                     "0:0:0:0:0:0:0:1", "0.0.0.0", "::", "::ffff:127.0.0.1"] {
            #expect(TunnelLoopbackHost.isLoopback(host), "\(host)")
        }
        for host in ["example.com", "localhost.example.com", "10.0.0.1", "127.1", "128.0.0.1", "::2", "fe80::1"] {
            #expect(!TunnelLoopbackHost.isLoopback(host), "\(host)")
        }
    }

    @Test func splitBackendRoutesByDestination() async throws {
        let exit = ScriptedBackend()
        let direct = ScriptedBackend()
        let split = SplitConnectBackend(exit: exit, direct: direct, sendsThroughExit: TunnelLoopbackHost.isLoopback)
        _ = try await split.open(host: "app.localhost", port: 3000)
        _ = try await split.open(host: "example.com", port: 443)
        #expect(exit.opens.map(\.0) == ["app.localhost"])
        #expect(direct.opens.map(\.0) == ["example.com"])
    }
}

@Suite struct TunnelConcurrencyLimitTests {
    @Test func slotsHandOffInOrderAndTheQueueIsBounded() async {
        let limit = TunnelConcurrencyLimit(limit: 1, maximumWaiters: 1)
        #expect(await limit.acquire())
        let waiter = Task { await limit.acquire() }
        while await limit.waiterCount == 0 { await Task.yield() }
        // The queue holds one waiter; the next acquirer fails fast.
        #expect(await limit.acquire() == false)
        await limit.release()
        #expect(await waiter.value)
        #expect(await limit.holderCount == 1)
        await limit.release()
        #expect(await limit.holderCount == 0)
    }
}

/// The relay reads one chunk per direction and waits for it to be written:
/// a stalled sink stops the source from being drained.
@Suite struct TunnelRelayBackpressureTests {
    final class CountingSource: TunnelByteStream, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        var reads: Int { lock.withLock { _reads } }
        func read() async throws -> Data? {
            lock.withLock { _reads += 1 }
            return Data(repeating: 1, count: 1024)
        }
        func write(_ data: Data) async throws {}
        func finishWriting() async {}
        func close() async {}
    }

    final class GatedSink: TunnelByteStream, @unchecked Sendable {
        private let lock = NSLock()
        private var _writes = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var closed = false
        var writes: Int { lock.withLock { _writes } }
        func read() async throws -> Data? {
            // Never sends anything until closed.
            while !lock.withLock({ closed }) { try await Task.sleep(for: .milliseconds(5)) }
            return nil
        }
        func write(_ data: Data) async throws {
            lock.withLock { _writes += 1 }
            await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
        }
        func openGate() {
            let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let gate = self.gate
                self.gate = nil
                return gate
            }
            gate?.resume()
        }
        func finishWriting() async {}
        func close() async {
            lock.withLock { closed = true }
            openGate()
        }
    }

    @Test(.timeLimit(.minutes(1))) func aStalledSinkBoundsReads() async throws {
        let source = CountingSource()
        let sink = GatedSink()
        let relay = Task { await TunnelRelay.run(source, sink) }
        while sink.writes < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.reads == 1)
        #expect(sink.writes == 1)
        sink.openGate()
        while sink.writes < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(source.reads == 2)
        relay.cancel()
        await sink.close()
        _ = await relay.value
    }
}
