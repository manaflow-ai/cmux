import Foundation
import Testing
@testable import CmuxNextDaemon

/// Real bridge framing and captured-transport behavior, without a user's daemon.
struct AgentCLIJobCarrierTests {
    private let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let session: ResourceID = "session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private struct Calls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-job-calls"
    }

    private var good: String {
        #"{"machine":"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","session":"session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","cli":"claude","revision":"18446744073709551615","replayed":false,"path":{"kind":"terminal","workspace_id":"ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","screen_id":"screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pane_id":"pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tab_id":"tab_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","terminal_id":"term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#
    }

    @Test func requestPreservesTheOriginalKeyAndBothConditions() throws {
        let key = "original-key with 'quotes' and \u{03c0}"
        let request = MachineAgentCLIUpdateJobRequest(expectedMachineID: machine, expectedSessionID: session,
                                                      cli: .claude, idempotencyKey: key)
        let data = try WireCoding.encodeRequest(request, id: 19)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .object(["id": .number(19), "cmd": .string("agent-cli-update-job"),
            "expected_machine_id": .string(machine.rawValue), "expected_session_id": .string(session.rawValue),
            "cli": .string("claude"), "idempotency_key": .string(key)]))
    }

    @Test func receiptRequiresCanonicalPublicIdentityAndExactRevision() throws {
        let receipt = try JSONDecoder().decode(AgentCLIJobReceipt.self, from: Data(good.utf8))
        #expect(receipt.machine == machine && receipt.session == session)
        #expect(receipt.cli == .claude && receipt.revision == UInt64.max)
        #expect(receipt.path.terminalID.rawValue == "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        for bad in [
            good.replacingOccurrences(of: machine.rawValue, with: "current"),
            good.replacingOccurrences(of: session.rawValue, with: "legacy-registry-id"),
            good.replacingOccurrences(of: "ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", with: "workspace:runtime-id"),
            good.replacingOccurrences(of: "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", with: "host:private-incarnation"),
            good.replacingOccurrences(of: "18446744073709551615", with: "18446744073709551616"),
            good.replacingOccurrences(of: #""18446744073709551615""#, with: "18446744073709551615"),
            good.replacingOccurrences(of: #""cli":"claude""#, with: #""cli":"unknown-future-cli""#),
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(AgentCLIJobReceipt.self, from: Data(bad.utf8))
            }
        }
    }

    @Test(arguments: ["good", "foreign-machine", "foreign-session", "foreign-cli", "bad-path", "bad-revision"])
    func startChecksTheReceiptAndSendsOnlyOneOriginalIntent(mode: String) async throws {
        try await withConnection(mode) { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            do {
                let receipt = try await carrier.startUpdate(cli: .claude, idempotencyKey: "original-job-key")
                #expect(mode == "good")
                #expect(receipt.machine == machine && receipt.session == session && receipt.cli == .claude)
                #expect(receipt.revision == UInt64.max)
            } catch DaemonError.malformedResponse {
                #expect(mode != "good")
            }
            let calls = try #require(try await connection.request(Calls()).arrayValue)
            #expect(calls.count == 1)
            let call = try #require(calls.first)
            #expect(call["cmd"] == .string("agent-cli-update-job"))
            #expect(call["expected_machine_id"] == .string(machine.rawValue))
            #expect(call["expected_session_id"] == .string(session.rawValue))
            #expect(call["cli"] == .string("claude"))
            #expect(call["idempotency_key"] == .string("original-job-key"))
            guard case .object(let fields) = call else { Issue.record("job request object"); return }
            #expect(Set(fields.keys) == ["id", "cmd", "expected_machine_id", "expected_session_id", "cli", "idempotency_key"])
        }
    }

    @Test(arguments: ["old", "unverified", "wrong-machine", "wrong-session"])
    func captureRequiresCapabilityProofAndBothIdentities(mode: String) async throws {
        try await withConnection(mode) { connection in
            do {
                _ = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
                Issue.record("unadmitted job carrier")
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(mode == "old" && missing == ["agent-cli-update-job-v1"])
            } catch DaemonError.command(_, _, let code, _, _) {
                #expect(mode == "unverified" && code == "agent_cli_job.not_trusted")
            } catch DaemonError.malformedResponse {
                #expect(mode == "wrong-machine" || mode == "wrong-session")
            }
            let calls = try await connection.request(Calls())
            #expect(calls.arrayValue?.isEmpty == true)
        }
    }

    @Test func retiredTransportCannotRedirectAnIntent() async throws {
        try await withConnection("good") { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            await connection.close()
            do {
                _ = try await carrier.startUpdate(cli: .claude, idempotencyKey: "retained-intent")
                Issue.record("retired transport executed a job")
            } catch let error as DaemonError {
                #expect(error.isLostConnection)
            }
        }
    }

    @Test(arguments: ["good", "inventory-old"])
    func inventoryUsesTheCapturedOwnerAndRequiresItsReadCapability(mode: String) async throws {
        try await withConnection(mode) { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            do {
                let inventory = try await carrier.inventory()
                #expect(mode == "good" && inventory.harnesses.isEmpty)
            } catch DaemonError.missingCapabilities(let capabilities) {
                #expect(mode == "inventory-old" && capabilities == ["agent-inventory-owner-v1"])
            }
            let calls = try #require(try await connection.request(Calls()).arrayValue)
            #expect(calls.count == (mode == "good" ? 1 : 0))
            if let call = calls.first {
                #expect(call["cmd"] == .string("agent-inventory"))
                #expect(call["expected_machine_id"] == .string(machine.rawValue))
                #expect(call["cli"] == nil && call["idempotency_key"] == nil)
            }
        }
    }

    @Test(arguments: ["empty-key", "control-key", "unknown-cli"])
    func invalidIntentIsRefusedBeforeAnyMutation(mode: String) async throws {
        try await withConnection("good") { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            do {
                _ = try await carrier.startUpdate(cli: mode == "unknown-cli" ? .unknown : .claude,
                    idempotencyKey: mode == "empty-key" ? "" : mode == "control-key" ? "key\n" : "original")
                Issue.record("malformed job intent was sent")
            } catch DaemonError.command(_, _, let code, _, _) {
                #expect(code == "agent_cli_job.bad_request")
            }
            let calls = try await connection.request(Calls())
            #expect(calls.arrayValue?.isEmpty == true)
        }
    }

    @Test func pendingAndUnknownOutcomesDoNotInventSuccess() throws {
        let pending = #"{"state":"pending","lifecycle":"running","terminal_id":"term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":"18446744073709551615"}"#
        let waiting = try JSONDecoder().decode(AgentCLIJobStatus.self, from: Data(pending.utf8))
        #expect(waiting.state == .pending && waiting.outcome == nil && waiting.exitedAt == nil)
        #expect(waiting.revision == UInt64.max)
        let unknown = #"{"state":"exited","lifecycle":"exited","terminal_id":"term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":"7","exited_at":"18446744073709551615","outcome":{"kind":"unknown","reason":"private diagnostic text"}}"#
        let ended = try JSONDecoder().decode(AgentCLIJobStatus.self, from: Data(unknown.utf8))
        #expect(ended.state == .exited && ended.outcome == .some(.unknown))
        #expect(ended.exitedAt == UInt64.max && ended.revision == 7)
        for bad in [
            pending.replacingOccurrences(of: #""revision":"18446744073709551615""#, with: #""revision":"18446744073709551616""#),
            pending.replacingOccurrences(of: #""state":"pending""#, with: #""state":"succeeded""#),
            pending.replacingOccurrences(of: #""lifecycle":"running""#, with: #""lifecycle":"exited""#),
            unknown.replacingOccurrences(of: "18446744073709551615", with: "18446744073709551616"),
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(AgentCLIJobStatus.self, from: Data(bad.utf8))
            }
        }
    }

    @Test(arguments: ["pending", "exited", "signal", "unknown", "foreign-terminal", "bad-observation", "contradictory-pending"])
    func observeReadsOnlyTheOriginalTerminalOnItsMachineAndSession(mode: String) async throws {
        try await withConnection(mode) { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            let receipt = try JSONDecoder().decode(AgentCLIJobReceipt.self, from: Data(good.utf8))
            do {
                let status = try await carrier.observe(receipt)
                #expect(status.terminalID == receipt.path.terminalID && status.revision == 7)
                switch mode {
                case "pending": #expect(status.state == .pending && status.outcome == nil)
                case "exited": #expect(status.state == .exited && status.outcome == .some(.exit(code: 23)))
                case "signal": #expect(status.state == .exited && status.outcome == .some(.signal(number: 9)))
                case "unknown": #expect(status.state == .exited && status.outcome == .some(.unknown))
                default: Issue.record("invalid terminal observation was admitted")
                }
            } catch DaemonError.malformedResponse {
                #expect(["foreign-terminal", "bad-observation", "contradictory-pending"].contains(mode))
            }
            let calls = try #require(try await connection.request(Calls()).arrayValue)
            #expect(calls.count == 1)
            let call = try #require(calls.first)
            #expect(call["protocol"] == .string("cmux.protocol/2"))
            #expect(call["operation"] == .string("terminal.wait_exit"))
            #expect(call["params"] == .object(["machine": .string(machine.rawValue), "session": .string(session.rawValue),
                "terminal": .string(receipt.path.terminalID.rawValue), "timeout_ms": .string("5000")]))
            #expect(call["cmd"] == nil && call["idempotency_key"] == nil)
        }
    }

    @Test(arguments: ["machine", "session"])
    func anObservationCannotSelectAnotherReceiptsOwner(field: String) async throws {
        try await withConnection("good") { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            let old = field == "machine" ? machine.rawValue : session.rawValue
            let other = (field == "machine" ? "machine_" : "session_") + String(repeating: "b", count: 32)
            let receipt = try JSONDecoder().decode(AgentCLIJobReceipt.self, from: Data(good.replacingOccurrences(of: old, with: other).utf8))
            do {
                _ = try await carrier.observe(receipt)
                Issue.record("foreign job receipt selected an observation route")
            } catch DaemonError.malformedResponse { }
            #expect(try await connection.request(Calls()).arrayValue?.isEmpty == true)
        }
    }

    @Test func retiredObservationTransportCannotReattach() async throws {
        try await withConnection("good") { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            let receipt = try JSONDecoder().decode(AgentCLIJobReceipt.self, from: Data(good.utf8))
            await connection.close()
            do {
                _ = try await carrier.observe(receipt)
                Issue.record("retired observation reattached")
            } catch let error as DaemonError {
                #expect(error.isLostConnection)
            }
        }
    }

    private func withConnection(_ mode: String, _ body: (DaemonConnection) async throws -> Void) async throws {
        let script = #"""
        import json, sys
        mode, calls = sys.argv[1], []
        machine, session = 'machine_' + 'a'*32, 'session_' + 'a'*32
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame, result = json.loads(line), {}
            cmd = frame.get('cmd')
            if cmd == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'job-boot','registry_id':'original-registry',
                    'capabilities':['machine-identity-v1'] + ([] if mode == 'old' else ['agent-cli-update-job-v1'])
                        + ([] if mode == 'inventory-old' else ['agent-inventory-owner-v1']),
                    'machine_id': 'machine_' + 'b'*32 if mode == 'wrong-machine' else machine,
                    'session_resource_id': 'session_' + 'b'*32 if mode == 'wrong-session' else session}
            elif cmd == 'client-hello':
                result = {'connection_id':'1','user_origin_allowed':mode != 'unverified'}
            elif cmd == 'agent-inventory':
                calls.append(frame)
                result = {'view':'inventory','cached':True,'harnesses':[]}
            elif cmd == 'agent-cli-update-job':
                calls.append(frame)
                result = {'machine':machine,'session':session,'cli':'claude','revision':'18446744073709551615',
                    'replayed':False,'path':{'kind':'terminal','workspace_id':'ws_'+'a'*32,'screen_id':'screen_'+'a'*32,
                    'pane_id':'pane_'+'a'*32,'tab_id':'tab_'+'a'*32,'terminal_id':'term_'+'a'*32}}
                if mode == 'foreign-machine': result['machine'] = 'machine_' + 'b'*32
                if mode == 'foreign-session': result['session'] = 'session_' + 'b'*32
                if mode == 'foreign-cli': result['cli'] = 'codex'
                if mode == 'bad-path': result['path']['terminal_id'] = 'private-host-id'
                if mode == 'bad-revision': result['revision'] = '18446744073709551616'
            elif frame.get('operation') == 'terminal.wait_exit':
                calls.append(frame)
                result = {'state':'exited','lifecycle':'exited','terminal_id':'term_'+'a'*32,
                    'revision':'7','exited_at':'1','outcome':{'kind':'exit','code':23}}
                if mode in ('pending', 'contradictory-pending'):
                    result = {'state':'pending','lifecycle':'running','terminal_id':'term_'+'a'*32,'revision':'7'}
                    if mode == 'contradictory-pending': result['outcome'] = {'kind':'exit','code':0}
                if mode == 'signal': result['outcome'] = {'kind':'signal','signal':9}
                if mode == 'unknown': result['outcome'] = {'kind':'unknown','reason':'private diagnostic text'}
                if mode == 'foreign-terminal': result['terminal_id'] = 'term_'+'b'*32
                if mode == 'bad-observation': result['revision'] = '18446744073709551616'
                print(json.dumps({'protocol':'cmux.protocol/2','type':'response','id':frame.get('id'),'ok':True,'result':result}), flush=True)
                continue
            elif cmd == 'test-job-calls': result = calls
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge.fakePython(["-c", script, mode])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-job-\(UUID().uuidString).sock", bridge: bridge)
        var configuration = DaemonConnection.Configuration(requiredCapabilities: [], terminalEnvironment: nil,
                                                           clientHello: .init(installKey: nil))
        configuration.heartbeat = .seconds(300)
        let connection = DaemonConnection(endpoint: endpoint, configuration: configuration)
        do {
            try await connection.start()
            try await body(connection)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
