import Foundation
import Testing
@testable import CmuxNextMobile

@Suite struct MobileHostControlPipeTests {
    /// A complete burst fits in the OS pipe, but exceeds the old 256-line stream.
    /// Wait for the writer to exit before consuming the burst.
    @Test(.timeLimit(.minutes(1))) func allThousandQueuedControlLinesArrive() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try Self.script(in: directory, body: """
        echo ready
        read start
        i=0
        while [ "$i" -lt 1000 ]; do
          echo "$i"
          i=$((i + 1))
        done
        """)
        let child = MobileHostProcess()
        try child.start(MobileHostTests.launch(executable: script), environment: [:], log: nil)
        defer { child.stop() }
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        #expect(child.send(Data("start\n".utf8)))
        #expect(await child.waitForExit() == 0)
        var received: [String] = []
        while let line = await lines.next() { received.append(line) }
        #expect(received == (0..<1000).map(String.init))
    }

    /// `send` queues the line on the feed and returns: a hostd that is not reading (here for a second)
    /// never holds the caller, which is the supervisor on the main actor. The line still arrives whole.
    @Test(.timeLimit(.minutes(1))) func sendNeverWaitsForHostdToRead() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try Self.script(in: directory, body: """
        echo ready
        sleep 1
        head -c 1048577 | wc -c
        """)
        let child = MobileHostProcess()
        try child.start(MobileHostTests.launch(executable: script), environment: [:], log: nil)
        defer { child.stop() }
        var lines = child.lines.makeAsyncIterator()
        #expect(await lines.next() == "ready")
        let clock = ContinuousClock()
        let start = clock.now
        #expect(child.send(Data(repeating: 0x61, count: 1_024 * 1_024) + Data("\n".utf8)))
        #expect(clock.now - start < .milliseconds(250))
        #expect(await lines.next()?.trimmingCharacters(in: .whitespaces) == "1048577")
    }

    /// The first token is held while hostd asks for it again and sends a pairing
    /// request. The request must arrive without a second token lookup or a wait.
    @Test(.timeLimit(.minutes(1))) func startupTokenRequestDoesNotRaceOrHoldPairing() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try Self.script(in: directory, body: """
        echo '{"type":"need_token"}'
        echo '{"type":"unpaired","phone_device_id":"test-phone"}'
        read token
        echo '{"type":"online","device_id":"d","team_id":"personal-u"}'
        while read line; do :; done
        """)
        let gate = TokenGate()
        let supervisor = MobileHostSupervisor()
        await supervisor.start(.init(launch: MobileHostTests.launch(executable: script), accessToken: { _ in
            await gate.fetch()
        }, acpmux: { nil }, log: nil))
        var pairing = supervisor.pairing.makeAsyncIterator()
        #expect(await pairing.next() == .unpaired(phoneDeviceID: "test-phone"))
        await gate.waitForFetch()
        #expect(await gate.calls == 1)
        await gate.release()
        for await state in supervisor.states where state.phase == .online { break }
        await supervisor.stop()
    }

    /// A stalled acpmux lookup must not consume the phone's approval window.
    /// The pairing and status events arrive while the endpoint is still held.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func acpmuxRefreshDoesNotHoldPairingOrShutdown(stopWhileHeld: Bool) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MobileHostPairingTests.identity
        let approval = MobileHostPairingTests.approval
        let script = try Self.script(in: directory, body: """
        i=0
        while [ "$i" -lt 32 ]; do
          echo '{"type":"need_acpmux"}'
          i=$((i + 1))
        done
        echo '{"type":"pair_request","phone_device_id":"test-phone","name":"Test phone","identity_key":"\(identity)","approval_key":"\(approval)"}'
        echo '{"type":"online","device_id":"d","team_id":"personal-u"}'
        while read line; do
          case "$line" in
            *'"type":"acpmux"'*) echo '{"type":"unpaired","phone_device_id":"endpoint-received"}' ;;
          esac
        done
        """)
        let gate = AcpmuxEndpointGate()
        let supervisor = MobileHostSupervisor()
        await supervisor.start(.init(launch: MobileHostTests.launch(executable: script), accessToken: { _ in "h.e.s" },
                                     acpmux: { await gate.fetch() }, log: nil))
        var pairing = supervisor.pairing.makeAsyncIterator()
        #expect(await pairing.next() == .pairRequest(MobileHostPairRequest(
            phoneDeviceID: "test-phone", name: "Test phone", identityKey: identity, approvalKey: approval)))
        for await state in supervisor.states where state.phase == .online { break }
        await gate.waitForFetch()
        #expect(await gate.calls == 1)
        if stopWhileHeld {
            await supervisor.stop()
            #expect(await supervisor.current.phase == .off)
            await gate.release(Self.endpoint)
        } else {
            await gate.release(Self.endpoint)
            #expect(await pairing.next() == .unpaired(phoneDeviceID: "endpoint-received"))
            await supervisor.stop()
        }
    }

    @Test(.timeLimit(.minutes(1))) func stoppedAcpmuxSupplyDiscardsLateAnswerAndCannotRestart() async throws {
        let gate = AcpmuxEndpointGate()
        let sent = AcpmuxEndpointLog()
        let supply = MobileHostAcpmuxSupply(fetch: { await gate.fetch() }, send: { sent.record($0.token) })
        let pending = try #require(await supply.request())
        await gate.waitForFetch()
        await supply.stop()
        #expect(await supply.request() == nil)
        // The provider deliberately ignores cancellation and returns a valid endpoint.
        await gate.release(Self.endpoint)
        await pending.value
        #expect(sent.values.isEmpty)
        #expect(await gate.calls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func unavailableAcpmuxEndpointAllowsAnotherLookup() async throws {
        let gate = AcpmuxEndpointGate()
        let sent = AcpmuxEndpointLog()
        let supply = MobileHostAcpmuxSupply(fetch: { await gate.fetch() }, send: { sent.record($0.token) })
        let unavailable = try #require(await supply.request())
        await gate.waitForFetch()
        await gate.release(nil)
        await unavailable.value
        #expect(sent.values.isEmpty)
        let retry = try #require(await supply.request())
        await gate.waitForFetch(count: 2)
        await gate.release(Self.endpoint)
        await retry.value
        #expect(sent.values == [Self.endpoint.token])
        #expect(await gate.calls == 2)
        await supply.stop()
    }

    private static let endpoint = (url: URL(string: "ws://127.0.0.1:12345")!, token: "test-token")

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-control-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func script(in directory: URL, body: String) throws -> URL {
        let script = directory.appendingPathComponent("host")
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private actor AcpmuxEndpointGate {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<MobileHostAcpmuxSupply.Endpoint?, Never>] = []
    private var started: CheckedContinuation<Void, Never>?
    private var wanted = 1

    func fetch() async -> MobileHostAcpmuxSupply.Endpoint? {
        calls += 1
        if calls >= wanted {
            started?.resume()
            started = nil
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func waitForFetch(count: Int = 1) async {
        if calls >= count { return }
        wanted = count
        await withCheckedContinuation { started = $0 }
    }

    func release(_ endpoint: MobileHostAcpmuxSupply.Endpoint?) {
        for continuation in waiting { continuation.resume(returning: endpoint) }
        waiting.removeAll()
    }
}

private final class AcpmuxEndpointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []

    var values: [String] { lock.withLock { tokens } }
    func record(_ token: String) { lock.withLock { tokens.append(token) } }
}

private actor TokenGate {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<String, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async -> String {
        calls += 1
        started?.resume()
        started = nil
        return await withCheckedContinuation { waiting.append($0) }
    }

    func waitForFetch() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        for continuation in waiting { continuation.resume(returning: "h.e.s") }
        waiting.removeAll()
    }
}
