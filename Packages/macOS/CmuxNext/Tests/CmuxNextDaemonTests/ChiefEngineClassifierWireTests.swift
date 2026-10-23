import Foundation
import Testing
@testable import CmuxNextDaemon

/// The reaction classifier on the `chief.engine.*` wire (a416): `engine` carries what the brain resolved
/// (this Chief's engine.json over the person's cmux.json), `choice` this Chief's own values, and a set
/// sends `classifier_harness`, `classifier_model`, `classifier_prompt` and `reactions_can_wake`.
struct ChiefEngineClassifierWireTests {
    static func report(_ json: String) throws -> ChiefEngineReport {
        try JSONDecoder().decode(ChiefEngineReport.self, from: Data(json.utf8))
    }

    @Test func theReportCarriesTheResolvedAndTheOwnValues() throws {
        let report = try Self.report("""
        {"engine": {"harness": "claude", "classifier_harness": "claude", "classifier_model": "claude-haiku-5-5",
                    "classifier_prompt": "", "reactions_can_wake": true},
         "choice": {"classifier_model": "claude-sonnet-5-5", "reactions_can_wake": "false"}}
        """)
        #expect(report.engine.classifierHarness == "claude")
        #expect(report.engine.classifierModel == "claude-haiku-5-5")
        #expect(report.engine.classifierPrompt == "")
        #expect(report.engine.reactionsCanWake == true)
        #expect(report.choice.classifierModel == "claude-sonnet-5-5")
        #expect(report.choice.reactionsCanWake == false, "engine.json may hold it as a string")
        #expect(report.choice.classifierHarness == nil)
    }

    @Test func anOlderBrainHasNone() throws {
        let report = try Self.report(#"{"engine": {"harness": "claude", "model": "claude-opus-5-5"}}"#)
        #expect(report.engine.harness == "claude")
        #expect(report.engine.classifierModel == nil && report.engine.reactionsCanWake == nil)
    }

    @Test func aSetSendsTheClassifierFields() {
        let params = ChiefControlClient.engineSetParams(["classifier_model": "claude-haiku-5-5", "reactions_can_wake": "false",
                                                         "classifier_prompt": "default", "bogus": "x"], chief: "chief_b")
        #expect(params == ["classifier_model": .string("claude-haiku-5-5"), "reactions_can_wake": .string("false"),
                           "classifier_prompt": .string("default"), "chief": .string("chief_b")])
    }
}
