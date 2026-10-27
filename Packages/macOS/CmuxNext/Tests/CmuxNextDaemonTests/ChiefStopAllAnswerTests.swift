import Foundation
import Testing
@testable import CmuxNextDaemon

/// The answer to `chief.stop {all: true}` (optchat-chief `stop_all`, #23344): `stopped` and
/// `subagents`, plus `errors` (always sent now: one line per subagent whose cancel acpmux
/// refused) and `note` (only when a stopped subagent was still starting). A daemon from before
/// #23344 sends neither, and its answer still decodes.
struct ChiefStopAllAnswerTests {
    private func decode(_ json: String) throws -> ChiefStopAll {
        try JSONDecoder().decode(ChiefStopAll.self, from: Data(json.utf8))
    }

    @Test func anAnswerWithARefusedCancelAndAStartingSubagentKeepsBoth() throws {
        let answer = try decode(#"""
        {"stopped":true,"subagents":["a1","a3"],"errors":["a2: its turn did not stop: acpmux: session busy"],
         "note":"a1 is still starting; it stops as soon as it starts."}
        """#)
        #expect(answer == ChiefStopAll(stopped: true, subagents: ["a1", "a3"],
                                       errors: ["a2: its turn did not stop: acpmux: session busy"],
                                       note: "a1 is still starting; it stops as soon as it starts."))
    }

    @Test func anAnswerWithNoRefusalAndNoStartingSubagentHasNoErrorsAndNoNote() throws {
        let answer = try decode(#"{"stopped":false,"subagents":["a1"],"errors":[]}"#)
        #expect(answer == ChiefStopAll(stopped: false, subagents: ["a1"]))
        #expect(answer.errors.isEmpty)
        #expect(answer.note == nil)
    }

    @Test func anOlderDaemonsAnswerStillDecodes() throws {
        let answer = try decode(#"{"stopped":true,"subagents":["a2","a12"]}"#)
        #expect(answer == ChiefStopAll(stopped: true, subagents: ["a2", "a12"], errors: [], note: nil))
    }

    /// The control client reads it inside the resource API's mutation result.
    @Test func theAnswerDecodesInsideTheMutationResult() throws {
        let result = try JSONDecoder().decode(ResourceMutationResult<ChiefStopAll>.self, from: Data(#"""
        {"value":{"stopped":false,"subagents":[],"errors":["a4: its turn did not stop: refused"]},"replayed":false}
        """#.utf8))
        #expect(result.value == ChiefStopAll(stopped: false, subagents: [], errors: ["a4: its turn did not stop: refused"]))
    }
}
