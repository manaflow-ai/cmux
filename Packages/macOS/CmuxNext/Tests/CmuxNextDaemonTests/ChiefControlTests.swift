import Foundation
import Testing
@testable import CmuxNextDaemon

/// `chief.engine.get` / `chief.engine.set` / `chief.stop` (cmux-tui
/// resource-operations-v2.json): the brain's engine report decodes as the
/// panel needs it, and every failure maps to one typed error the panel can
/// say (2026-10-08: the Chief Settings panel of a cloud Chief must read and
/// set that server's brain, and say when it cannot).
@Suite struct ChiefControlTests {
    static let report = """
    {"engine": {"harness": "codex", "model": "gpt-6-sol", "effort": "medium", "compactor_harness": null, "compactor_model": null},
     "choice": {"harness": "codex", "model": "gpt-6-sol"},
     "last_turn": {"harness": "codex", "harness_profile": "codex", "model": "gpt-6-sol", "status": "ok", "ms": 2500,
                   "tools": 3, "tool_errors": 1, "cost_usd": null, "usage": {"cache_read": 90, "cache_write": 0, "input": 10}, "reply": "Done."},
     "recent": [{"harness": "codex", "model": "gpt-6-sol", "status": "ok", "ms": 2500, "tools": 3, "tool_errors": 1, "reply": "Done."}]}
    """

    @Test func theEngineReportDecodesTheChoiceAndTheRecentTurns() throws {
        let report = try JSONDecoder().decode(ChiefEngineReport.self, from: Data(Self.report.utf8))
        #expect(report.engine.harness == "codex")
        #expect(report.engine.model == "gpt-6-sol")
        #expect(report.choice.harness == "codex")
        #expect(report.choice.effort == nil, "the choice leaves effort to the default")
        #expect(report.recent.count == 1)
        #expect(report.recent[0].reply == "Done.")
        #expect(report.recent[0].tools == 3 && report.recent[0].toolErrors == 1)
    }

    @Test func everyFailureIsOneTypedError() {
        let refused = DaemonError.command(cmd: "chief.engine.set", message: "operation failed", code: "operation.failed",
                                          details: .object(["reason": .string("unknown_harness"),
                                                            "extra": .object(["message": .string("no harness claude-nope")])]))
        #expect(ChiefControlError(refused) == .refused(reason: "unknown_harness", message: "no harness claude-nope"))
        let notConfigured = DaemonError.command(cmd: "chief.engine.get", message: "x", code: "operation.failed",
                                                details: .object(["reason": .string("not_configured")]))
        #expect(ChiefControlError(notConfigured) == .notConfigured)
        let down = DaemonError.command(cmd: "chief.engine.get", message: "x", code: "operation.failed",
                                       details: .object(["reason": .string("unavailable")]))
        #expect(ChiefControlError(down) == .unreachable)
        #expect(ChiefControlError(DaemonError.notConnected) == .unreachable)
        #expect(ChiefControlError(DaemonError.connectionClosed(reason: "eof")) == .unreachable)
        let forbidden = DaemonError.command(cmd: "chief.stop", message: "x", code: "origin.forbidden")
        #expect(ChiefControlError(forbidden) == .forbidden)
        let old = DaemonError.command(cmd: "chief.stop", message: "unknown operation", code: "validation.invalid")
        #expect(ChiefControlError(old) == .unsupported)
    }
}
