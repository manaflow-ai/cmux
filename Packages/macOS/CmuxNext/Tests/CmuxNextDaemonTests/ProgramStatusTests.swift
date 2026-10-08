import Foundation
import Testing
@testable import CmuxNextDaemon

/// OSC 7501 program status (contract .cmux-scratch/nx-osc7501/CONTRACT.md v1):
/// terminal upserts carry `extra.program_status`; the store lays the records
/// on the terminal's tab, and an upsert without the field clears them.
@MainActor @Suite struct ProgramStatusTests {
    typealias S = SessionStateTests

    static func terminalUpsert(_ extra: String) -> String {
        S.item(#"""
        {"kind":"delta","cursor":{"generation":"g","revision":"7"},"previous_revision":"4","revision":"7","changes":[
          {"kind":"upsert","sequence":0,"resource":"terminal","id":"\#(S.terminal)","value":{"id":"\#(S.terminal)","tab_id":"\#(S.tab)","tab_ids":["\#(S.tab)"],"title":"t","cols":80,"rows":24,"running":true,"lifecycle":"running"\#(extra)}}
        ]}
        """#)
    }

    private func event(_ line: String) -> DaemonEvent {
        DaemonEvent.decode(name: LineTransport.streamEvent, line: Data(line.utf8))
    }

    @Test func recordsDecodeWithTheContractsRules() throws {
        let line = Self.terminalUpsert(#","extra":{"program_status":[{"id":"","state":"blocked","progress":140,"kind":"permission","app":"terraform","title":"Plan","msg":"Apply?","updated_seq":"17","updated_at_ms":"1"},{"id":"build","state":"working","progress":40,"kind":null,"app":null,"title":null,"msg":null,"updated_seq":"9","updated_at_ms":"1"},{"id":"x","state":"clear","updated_seq":"3"},{"id":"y","state":"blocked","kind":"telepathy","updated_seq":"4"}]}"#)
        guard case .sessionState(.delta(let changes)) = event(line), case .terminal(_, _, let records)? = changes.first else {
            Issue.record("no terminal change")
            return
        }
        // `clear` is never stored; an unknown kind is nil; progress is clamped.
        #expect(records.map(\.id) == ["", "build", "y"])
        #expect(records[0] == ProgramStatusRecord(id: "", state: .blocked, progress: 100, kind: .permission, app: "terraform",
                                                  title: "Plan", msg: "Apply?", updatedSeq: 17))
        #expect(records[2].kind == nil)
        // Two blocked records: the newer report (updated_seq 17) wins.
        #expect(ProgramStatusRecord.strongest(records)?.id == "")
    }

    @Test func theAggregateIsBlockedThenErrorThenWorkingThenDone() {
        let done = ProgramStatusRecord(id: "a", state: .done, updatedSeq: 9)
        let working = ProgramStatusRecord(id: "b", state: .working, updatedSeq: 1)
        let error = ProgramStatusRecord(id: "c", state: .error, updatedSeq: 2)
        let blocked = ProgramStatusRecord(id: "d", state: .blocked, updatedSeq: 3)
        let idle = ProgramStatusRecord(id: "e", state: .idle, updatedSeq: 10)
        #expect(ProgramStatusRecord.strongest([done, working]) == working)
        #expect(ProgramStatusRecord.strongest([done, working, error]) == error)
        #expect(ProgramStatusRecord.strongest([blocked, error, working]) == blocked)
        #expect(ProgramStatusRecord.strongest([idle]) == nil)
        #expect(ProgramStatusRecord.strongest([]) == nil)
    }

    @Test func theStoreLaysRecordsOnTheTabAndClearsThem() throws {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        store.noteHandshake(DaemonCompatibilityTests.identity([DaemonCapabilities.shared.stateResources]))
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: event(S.snapshot))])
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.resourceID?.rawValue == S.tab })
        #expect(tab.programStatus.isEmpty)
        let working = Self.terminalUpsert(#","extra":{"program_status":[{"id":"","state":"working","progress":40,"updated_seq":"1","updated_at_ms":"1"}]}"#)
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: event(working))])
        #expect(tab.programStatus == [ProgramStatusRecord(state: .working, progress: 40, updatedSeq: 1)])
        store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: event(Self.terminalUpsert("")))])
        #expect(tab.programStatus.isEmpty)
    }
}
