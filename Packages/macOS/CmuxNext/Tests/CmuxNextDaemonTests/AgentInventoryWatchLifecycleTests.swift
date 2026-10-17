import Foundation
import Testing
@testable import CmuxNextDaemon

/// Real transport waits and cancellation, with explicit fixture acknowledgements.
@Suite(.timeLimit(.minutes(1)))
struct AgentInventoryWatchLifecycleTests {
    private struct Inspect: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-state"
    }
    private struct WaitPending: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "test-wait-pending"
    }
    private struct Release: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "test-release"
    }
    private struct Drop: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "test-drop"
    }

    private let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let watchID = "inventory_watch_0123456789abcdef0123456789abcdef"

    @Test func capturesShareOneManagerAndRetirementPrecedesReadmission() async throws {
        try await withConnection { connection in
            let first = try await connection.agentInventoryWatch(expectedMachineID: machine)
            let second = try await connection.agentInventoryWatch(expectedMachineID: machine)
            #expect(first === second)
            let initial = try await first.enable()
            #expect(try await second.enable() == initial)
            try await first.disable()
            try await second.disable()
            _ = try await second.enable()
            try await second.disable()
            let calls = try await connection.request(Inspect())
            #expect(calls.arrayValue?.map { $0["enabled"] } == [.bool(true), .bool(false), .bool(true), .bool(false)])
            #expect(calls.arrayValue?.filter { $0["enabled"] == .bool(false) }.allSatisfy { $0["expected_watch_id"] == .string(watchID) } == true)
        }
    }

    @Test func cancellationRetainsTheWithheldReceiptThenConditionallyDisables() async throws {
        try await withConnection(mode: "hold") { connection in
            let watch = try await connection.agentInventoryWatch(expectedMachineID: machine)
            let enable = Task { try await watch.enable() }
            _ = try await connection.request(WaitPending())
            enable.cancel()
            _ = try await connection.request(Release())
            do { _ = try await enable.value; Issue.record("cancelled admission returned a live receipt") }
            catch is CancellationError { }
            try await watch.disable()
            let calls = try await connection.request(Inspect())
            #expect(calls.arrayValue?.map { $0["enabled"] } == [.bool(true), .bool(false)])
            #expect(calls.arrayValue?.last?["expected_watch_id"] == .string(watchID))
        }
    }

    @Test func refusedCleanupRemainsFailedAndCannotReadmit() async throws {
        try await withConnection(mode: "refuse-cleanup") { connection in
            let watch = try await connection.agentInventoryWatch(expectedMachineID: machine)
            _ = try await watch.enable()
            do { try await watch.disable(); Issue.record("cleanup refusal was swallowed") }
            catch let DaemonError.command(_, _, code, _, _) { #expect(code == "test.cleanup_refused") }
            do { _ = try await watch.enable(); Issue.record("uncertain cleanup readmitted a watch") }
            catch let DaemonError.command(_, _, code, _, _) { #expect(code == "test.cleanup_refused") }
            #expect(try await connection.request(Inspect()).arrayValue?.count == 2)
        }
    }

    @Test func foreignAdmissionAndReceiptCannotBecomeLive() async throws {
        try await withConnection(mode: "foreign-receipt") { connection in
            do {
                _ = try await connection.agentInventoryWatch(expectedMachineID: "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
                Issue.record("foreign route admitted")
            } catch DaemonError.malformedResponse { }
            #expect(try await connection.request(Inspect()).arrayValue?.isEmpty == true)
            let watch = try await connection.agentInventoryWatch(expectedMachineID: machine)
            do { _ = try await watch.enable(); Issue.record("foreign receipt admitted") }
            catch DaemonError.malformedResponse { }
            do { _ = try await watch.enable(); Issue.record("uncertain admission retried") }
            catch DaemonError.malformedResponse { }
            #expect(try await connection.request(Inspect()).arrayValue?.count == 1)
        }
    }

    @Test func sameOwnerReconnectNeverRedirectsOldCleanup() async throws {
        try await withConnection { connection in
            let old = try await connection.agentInventoryWatch(expectedMachineID: machine)
            _ = try await old.enable()
            _ = try await connection.request(Drop())
            var connected = 0
            for try await event in connection.events {
                if case .connected = event.event { connected += 1 }
                if connected == 2 { break }
            }
            let fresh = try await connection.agentInventoryWatch(expectedMachineID: machine)
            #expect(old !== fresh)
            _ = try await fresh.enable()
            do { _ = try await old.enable(); Issue.record("closed transport returned a cached live receipt") }
            catch { #expect((error as? DaemonError)?.isLostConnection == true) }
            do { try await old.disable(); Issue.record("closed transport acknowledged cleanup") }
            catch { #expect((error as? DaemonError)?.isLostConnection == true) }
            let calls = try await connection.request(Inspect())
            #expect(calls.arrayValue?.map { $0["enabled"] } == [.bool(true)])
            try await fresh.disable()
        }
    }

    private func withConnection(mode: String = "normal", _ body: (DaemonConnection) async throws -> Void) async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.bridgeScript, mode])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-watch-lifecycle-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            try await body(connection)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private static let bridgeScript = #"""
    import json, sys, uuid
    boot = str(uuid.uuid4())
    mode = sys.argv[1]
    calls, pending, waiting = [], None, None
    machine = 'machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    def reply(frame, result={}, ok=True):
        value = {'id':frame.get('id'), 'ok':ok, 'data':result}
        if not ok: value.update(error='cleanup refused', error_code='test.cleanup_refused')
        print(json.dumps(value), flush=True)
    def receipt():
        return {'machine': 'machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' if mode == 'foreign-receipt' else machine,
            'watch_id':'inventory_watch_0123456789abcdef0123456789abcdef', 'revision':18446744073709551615}
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        cmd = frame.get('cmd')
        if cmd == 'identify':
            reply(frame, {'app':'cmux-tui','protocol':12,'generation':boot, 'machine_id':machine,
                'capabilities':['agent-inventory-watch-fence-v1']})
        elif cmd == 'agent-inventory-watch':
            calls.append(frame)
            if frame['enabled'] and mode == 'hold':
                pending = frame
                if waiting is not None: reply(waiting); waiting = None
            elif frame['enabled']: reply(frame, receipt())
            else: reply(frame, ok=mode != 'refuse-cleanup')
        elif cmd == 'test-wait-pending':
            if pending is not None: reply(frame)
            else: waiting = frame
        elif cmd == 'test-release':
            if pending is not None: reply(pending, receipt()); pending = None
            reply(frame)
        elif cmd == 'test-state': reply(frame, calls)
        elif cmd == 'test-drop': reply(frame); break
        else: reply(frame)
    """#
}
