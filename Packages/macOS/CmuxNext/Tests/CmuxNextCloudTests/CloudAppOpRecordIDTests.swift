import CmuxNextCloud
import CmuxNextDaemon
import Testing

/// A machine change's answer (`cloud.snapshot.create` answers `{"snapshot": {"id"}}`, `cloud.snapshot.restore`
/// `{"machine": {"id"}}`): the App reads the named record's id, and an answer without one is a bad response,
/// never an empty id a fork would restore from.
@Suite struct CloudAppOpRecordIDTests {
    @Test func theNamedRecordsIDIsTheAnswer() throws {
        let answer = JSONValue.object(["snapshot": .object(["id": .string("snap_1"), "state": .string("creating")])])
        #expect(try answer.recordID("snapshot", op: "cloud.snapshot.create") == "snap_1")
    }

    @Test func noRecordAskedReadsNothing() throws {
        #expect(try JSONValue.object([:]).recordID(nil, op: "cloud.machine.resize") == nil)
    }

    @Test(arguments: [
        JSONValue.object([:]),
        .object(["machine": .object(["id": .string("vm_1")])]),
        .object(["snapshot": .object(["id": .string("")])]),
        .object(["snapshot": .object(["id": .number(7)])]),
    ])
    func anAnswerWithoutTheRecordsIDIsABadResponse(_ answer: JSONValue) {
        #expect(throws: CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.snapshot.create answered no snapshot")) {
            try answer.recordID("snapshot", op: "cloud.snapshot.create")
        }
    }
}
