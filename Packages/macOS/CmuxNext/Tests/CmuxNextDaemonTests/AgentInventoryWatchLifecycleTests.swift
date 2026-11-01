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

    @Test(arguments: ["unavailable", "busy"])
    func explicitNoLeaseRefusalAllowsFreshAdmissionOnSameTransport(code: String) async throws {
        try await withConnection(mode: "refused-first-\(code)") { connection in
            let watch = try await connection.agentInventoryWatch(expectedMachineID: machine)
            do { _ = try await watch.enable(); Issue.record("first admission did not refuse") }
            catch let DaemonError.command(_, _, actual, _, _) { #expect(actual == "agent_inventory.\(code)") }
            // A new demand cycle must not remain poisoned by a proven absent lease.
            do { try await watch.disable() }
            catch { Issue.record("no-lease refusal poisoned retirement: \(error)") }
            do {
                let receipt = try await watch.enable()
                #expect(receipt.machine == machine)
                try await watch.disable()
            } catch { Issue.record("new explicit admission retained old refusal: \(error)") }
            let calls = try await connection.request(Inspect()).arrayValue
            #expect(calls?.map { $0["enabled"] } == [.bool(true), .bool(true), .bool(false)])
            #expect(calls?.filter { $0["enabled"] == .bool(true) }.allSatisfy { $0["admission_receipt"] == .bool(true) } == true)
        }
    }

    @Test(arguments: ["ambiguous-busy", "foreign-proof", "legacy-proof", "invalid-proof", "unknown-proof"])
    func uncertainOrUnnegotiatedRefusalCannotReadmit(mode: String) async throws {
        try await withConnection(mode: mode) { connection in
            let watch = try await connection.agentInventoryWatch(expectedMachineID: machine)
            for _ in 0..<2 {
                do { _ = try await watch.enable(); Issue.record("unproven refusal admitted another watch") }
                catch DaemonError.command { }
            }
            do { try await watch.disable(); Issue.record("uncertain admission acknowledged cleanup") }
            catch DaemonError.command { }
            #expect(try await connection.request(Inspect()).arrayValue?.count == 1)
        }
    }

    @Test func cancellationRecoversNoLeaseRefusalWithoutSendingUnfencedCleanup() async throws {
        try await withConnection(mode: "hold-refusal") { connection in
            let watch = try await connection.agentInventoryWatch(expectedMachineID: machine)
            let admission = Task { try await watch.enable() }
            _ = try await connection.request(WaitPending())
            admission.cancel()
            _ = try await connection.request(Release())
            do { _ = try await admission.value; Issue.record("cancelled admission returned") }
            catch is CancellationError { }
            try await watch.disable()
            _ = try await watch.enable()
            try await watch.disable()
            #expect(try await connection.request(Inspect()).arrayValue?.map { $0["enabled"] } == [.bool(true), .bool(true), .bool(false)])
        }
    }

    @Test(arguments: ["legacy", "anonymous"])
    func unsupportedOrUnidentifiedOwnerNeverReceivesWatch(mode: String) async throws {
        try await withConnection(mode: mode) { connection in
            do {
                _ = try await connection.agentInventoryWatch(expectedMachineID: machine)
                Issue.record("unadmitted owner returned a watch manager")
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(mode == "legacy")
                #expect(missing == ["agent-inventory-watch-fence-v1"])
            } catch DaemonError.malformedResponse { #expect(mode == "anonymous") }
            #expect(try await connection.request(Inspect()).arrayValue?.isEmpty == true)
        }
    }

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
        let bridge = DaemonBridge.fakePython(["-c", Self.bridgeScript, mode])
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
    def refusal(frame):
        code = 'agent_inventory.' + mode.removeprefix('refused-first-') if mode.startswith('refused-first-') else 'agent_inventory.busy'
        details = {'machine':machine,'admission':'not_admitted'}
        if mode == 'ambiguous-busy': details = {}
        if mode == 'foreign-proof': details['machine'] = 'machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        if mode == 'invalid-proof': details['admission'] = True
        if mode == 'unknown-proof': code = 'agent_inventory.invalid_response'
        print(json.dumps({'id':frame['id'],'ok':False,'error':code,'error_code':code,'data':details}), flush=True)
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        cmd = frame.get('cmd')
        if cmd == 'identify':
            reply(frame, {'app':'cmux-tui','protocol':12,'generation':boot,
                'machine_id':'' if mode == 'anonymous' else machine,
                'capabilities':['agent-inventory-watch-v1'] if mode == 'legacy' else ['agent-inventory-watch-fence-v1'] + (['agent-inventory-watch-admission-v1'] if mode.startswith('refused-first-') or mode in ['ambiguous-busy','foreign-proof','invalid-proof','unknown-proof','hold-refusal'] else [])})
        elif cmd == 'agent-inventory-watch':
            calls.append(frame)
            if frame['enabled'] and len(calls) == 1 and (mode.startswith('refused-first-') or mode in ['ambiguous-busy','foreign-proof','legacy-proof','invalid-proof','unknown-proof']):
                refusal(frame)
            elif frame['enabled'] and (mode == 'hold' or mode == 'hold-refusal' and len(calls) == 1):
                pending = frame
                if waiting is not None: reply(waiting); waiting = None
            elif frame['enabled']: reply(frame, receipt())
            else: reply(frame, ok=mode != 'refuse-cleanup')
        elif cmd == 'test-wait-pending':
            if pending is not None: reply(frame)
            else: waiting = frame
        elif cmd == 'test-release':
            if pending is not None:
                if mode == 'hold-refusal': refusal(pending)
                else: reply(pending, receipt())
                pending = None
            reply(frame)
        elif cmd == 'test-state': reply(frame, calls)
        elif cmd == 'test-drop': reply(frame); break
        else: reply(frame)
    """#
}
