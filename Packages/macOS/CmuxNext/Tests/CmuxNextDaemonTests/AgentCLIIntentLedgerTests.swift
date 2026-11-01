import Foundation
import Testing
@testable import CmuxNextDaemon

/// Real transport framing; the fixture contains only public identities and
/// records whether recovery attempted an execution command.
struct AgentCLIIntentLedgerTests {
    let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let session: ResourceID = "session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let owner: ResourceID = "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let ownerSession: ResourceID = "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private struct Calls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-recovery-calls"
    }

    private func intent() throws -> AgentCLIUpdateIntent {
        try .init(key: "original-child", rootKey: "original-root", machine: owner, session: ownerSession,
                  cli: .claude, profiles: ["work-profile"])
    }

    private var receipt: String {
        #"{"machine":"machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","session":"session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","cli":"claude","revision":"18446744073709551615","replayed":true,"path":{"kind":"terminal","workspace_id":"ws_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","screen_id":"screen_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","pane_id":"pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tab_id":"tab_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","terminal_id":"term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}"#
    }

    @Test func recordsOriginalIdentityBeforeAttachingOnlyItsPublicReceipt() async throws {
        try await withConnection("good") { connection in
            let ledger = try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
            let original = try intent()
            let recorded = try await ledger.record([original])
            #expect(recorded.map(\.intent) == [original] && recorded.first?.receipt == nil)
            let listed = try await ledger.list()
            #expect(listed == recorded)
            let receipt = try JSONDecoder().decode(AgentCLIJobReceipt.self, from: Data(self.receipt.utf8))
            let attached = try await ledger.attach(key: original.key, receipt: receipt)
            #expect(attached.intent == original && attached.receipt == receipt)
            let calls = try #require(try await connection.request(Calls()).arrayValue)
            #expect(calls.count == 3)
            #expect(calls.map { $0["cmd"]?.stringValue } == ["agent-cli-intents-record", "agent-cli-intents-list", "agent-cli-intents-attach"])
            for call in calls {
                #expect(call["expected_machine_id"] == .string(machine.rawValue))
                #expect(call["expected_session_id"] == .string(session.rawValue))
                #expect(call["actor"] == nil && call["origin"] == nil && call["argv"] == nil)
            }
            #expect(calls[0]["intents"]?.arrayValue?.first?["key"] == .string("original-child"))
            #expect(calls[0]["intents"]?.arrayValue?.first?["root_key"] == .string("original-root"))
            #expect(calls[0]["intents"]?.arrayValue?.first?["machine"] == .string(owner.rawValue))
            #expect(calls[2]["receipt"]?["revision"] == .string("18446744073709551615"))
        }
    }

    @Test(arguments: ["old", "unverified", "foreign"])
    func ledgerCaptureRequiresItsOriginalOwnerAndFrontendProof(mode: String) async throws {
        try await withConnection(mode) { connection in
            do {
                _ = try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
                Issue.record("unadmitted recovery ledger")
            } catch {}
            let calls = try await connection.request(Calls())
            #expect(calls.arrayValue?.isEmpty == true)
        }
    }

    @Test func aForgedRecordAcknowledgementCannotSettleAnotherIntent() async throws {
        try await withConnection("forged-ack") { connection in
            let ledger = try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
            do { _ = try await ledger.record([intent()]); Issue.record("foreign intent acknowledgement") }
            catch {}
        }
    }

    @Test func settlingSendsOnlyTheKeysAndRejectsALedgerThatKeptThem() async throws {
        try await withConnection("good") { connection in
            let ledger = try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
            try await ledger.settle(keys: ["original-child"])
            let calls = try #require(try await connection.request(Calls()).arrayValue)
            #expect(calls.map { $0["cmd"]?.stringValue } == ["agent-cli-intents-settle"])
            #expect(calls.first?["keys"]?.arrayValue?.map(\.stringValue) == ["original-child"])
            #expect(calls.first?["expected_machine_id"] == .string(machine.rawValue) && calls.first?["argv"] == nil)
        }
        try await withConnection("kept") { connection in
            let ledger = try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
            do { try await ledger.settle(keys: ["original-child"]); Issue.record("a kept intent read as settled") }
            catch {}
        }
    }

    @Test func retiredLedgerCannotReconnectOrDispatchAnUpdate() async throws {
        try await withConnection("good") { connection in
            let ledger = try await connection.agentCLIIntentLedger(expectedMachineID: machine, expectedSessionID: session)
            await connection.close()
            do { _ = try await ledger.list(); Issue.record("retired ledger reconnected") }
            catch {}
        }
    }

    @Test(arguments: ["not_found", "pending", "indeterminate", "created"])
    func resolvingAnOriginalKeyNeverUsesTheExecutionCommand(state: String) async throws {
        try await withConnection(state) { connection in
            let carrier = try await connection.agentCLIJobs(expectedMachineID: machine, expectedSessionID: session)
            let resolved = try await carrier.resolveUpdate(cli: .claude, idempotencyKey: "original-child")
            switch (state, resolved) {
            case ("not_found", .notFound), ("pending", .pending), ("indeterminate", .indeterminate): break
            case ("created", .created(let receipt)): #expect(receipt.machine == machine && receipt.session == session)
            default: Issue.record("lost owner resolution state")
            }
            let calls = try #require(try await connection.request(Calls()).arrayValue)
            #expect(calls.count == 1)
            #expect(calls[0]["cmd"] == .string("agent-cli-update-job-resolve"))
            #expect(calls[0]["idempotency_key"] == .string("original-child"))
            #expect(calls[0]["expected_machine_id"] == .string(machine.rawValue))
            #expect(calls[0]["expected_session_id"] == .string(session.rawValue))
        }
    }

    private func withConnection(_ mode: String, _ body: (DaemonConnection) async throws -> Void) async throws {
        let script = #"""
        import json,sys
        mode,calls=sys.argv[1],[]
        machine,session='machine_'+'a'*32,'session_'+'a'*32
        intent={'key':'original-child','root_key':'original-root','machine':'machine_'+'b'*32,
          'session':'session_'+'b'*32,'cli':'claude','profiles':['work-profile']}
        receipt={'machine':intent['machine'],'session':intent['session'],'cli':'claude',
          'revision':'18446744073709551615','replayed':True,'path':{'kind':'terminal',
          'workspace_id':'ws_'+'b'*32,'screen_id':'screen_'+'b'*32,'pane_id':'pane_'+'b'*32,
          'tab_id':'tab_'+'b'*32,'terminal_id':'term_'+'b'*32}}
        print('{"ok":true}',file=sys.stderr,flush=True)
        for line in sys.stdin:
          frame=json.loads(line);cmd=frame.get('cmd');result={}
          if cmd=='identify':
            result={'app':'cmux-tui','protocol':12,'generation':'recovery-boot','registry_id':'original-registry',
              'capabilities':['machine-identity-v1','agent-cli-update-job-v1']+([] if mode=='old' else ['agent-cli-intents-v1','agent-cli-update-job-resolve-v1']),
              'machine_id':('machine_'+'c'*32 if mode=='foreign' else machine),'session_resource_id':session}
          elif cmd=='client-hello':result={'connection_id':'1','user_origin_allowed':mode!='unverified'}
          elif cmd in ('agent-cli-intents-record','agent-cli-intents-list'):
            calls.append(frame)
            row=dict(intent,receipt=None)
            if mode=='forged-ack':row['key']='another-intent'
            result={'intents':[row],'changed':cmd.endswith('record')}
          elif cmd=='agent-cli-intents-settle':
            calls.append(frame)
            result={'intents':[dict(intent,receipt=None)] if mode=='kept' else [],'changed':mode!='kept'}
          elif cmd=='agent-cli-intents-attach':
            calls.append(frame);result={'intent':dict(intent,receipt=receipt),'changed':True}
          elif cmd=='agent-cli-update-job-resolve':
            calls.append(frame);result={'state':mode}
            if mode=='created':result['receipt']=dict(receipt,machine=machine,session=session)
          elif cmd in ('set-client-info','subscribe'):pass
          elif cmd=='test-recovery-calls':result=calls
          else:raise RuntimeError('recovery must not execute '+str(cmd))
          print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}),flush=True)
        """#
        let bridge = DaemonBridge.fakePython(["-c", script, mode])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-recovery-\(UUID().uuidString).sock", bridge: bridge)
        var configuration = DaemonConnection.Configuration(requiredCapabilities: [], terminalEnvironment: nil, clientHello: .init(installKey: nil))
        configuration.heartbeat = .seconds(300)
        let connection = DaemonConnection(endpoint: endpoint, configuration: configuration)
        do { try await connection.start(); try await body(connection); await connection.close() }
        catch { await connection.close(); throw error }
    }
}
