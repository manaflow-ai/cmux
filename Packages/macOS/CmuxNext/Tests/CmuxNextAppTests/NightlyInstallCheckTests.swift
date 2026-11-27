@testable import CmuxNextUpdater
import Foundation
import Testing

/// The Swift host of NIGHTLY's install check speaks the Rust CLI's JSON (`cmux __install-check`,
/// cmux-tui `cmux-install-check`, whose `cli_due_then_decide` test pins the same shapes), and words
/// each decision as the one line the person reads.
@Suite struct NightlyInstallCheckTests {
    private static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theRequestCarriesEachCanaryResult() throws {
        let kept = [InstallCheckKept(build: "7", readsStore: true)]
        let refused = try Self.json(InstallCheckRequest(build: "8", result: .refused("transport.intent_invalid", retryable: false), kept: kept))
        #expect(refused["nightly"] as? Bool == true)
        #expect(refused["build"] as? String == "8")
        let canary = try #require(refused["canary"] as? [String: Any])
        #expect(canary["result"] as? String == "refused")
        #expect(canary["reason"] as? String == "transport.intent_invalid")
        #expect(canary["retryable"] as? Bool == false)
        let busy = try Self.json(InstallCheckRequest(build: "8", result: .refused("connection.busy", retryable: true), kept: []))
        #expect((busy["canary"] as? [String: Any])?["retryable"] as? Bool == true)
        #expect((refused["kept"] as? [[String: Any]])?.first?["readsStore"] as? Bool == true)
        #expect(try Self.json(InstallCheckRequest(build: "8", result: .passed, kept: []))["canary"] as? [String: String] == ["result": "passed"])
        #expect(try Self.json(InstallCheckRequest(build: "8", result: .inconclusive("timeout"), kept: []))["canary"] as? [String: String] == ["result": "inconclusive"])
    }

    @Test func aRollBackDecodes() throws {
        let output = #"{"action":{"kind":"rollBack","to":"7"},"record":{"build":"8","result":"refused"},"pin":"8","notice":{"build":"8","target":"7","reason":"no"}}"#
        let decision = try JSONDecoder().decode(InstallCheckDecision.self, from: Data(output.utf8))
        #expect(decision.action == .init(kind: .rollBack, to: "7", why: nil))
        #expect(decision.pin == "8")
    }

    /// The held notice the target build's launch shows (`cmux __install-check show`, whose
    /// `cli_holds_and_shows_once` test pins the same shape): one line, what, why and how to undo.
    @Test func aShownRollBackReadsAsOneLine() throws {
        let output = #"{"kind":"rolledBack","notice":{"build":"8","target":"7","reason":"no"}}"#
        let notice = NightlyInstallCheckNotice(try JSONDecoder().decode(InstallCheckShow.self, from: Data(output.utf8)))
        #expect(notice.title.contains("7"))
        #expect(notice.body == UpdaterStrings.installCheckRolledBack("8", "no", "7"))
        #expect(!notice.body.contains("\n"))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(InstallCheckShow.self, from: Data("null".utf8)) }
    }

    @Test func aReportDecodesAndReadsAsStayed() throws {
        for why in ["noPassingBuild", "storeUnreadable"] {
            let output = #"{"action":{"kind":"report","why":"\#(why)"},"record":{"build":"8","result":"refused"},"pin":"8","notice":{"build":"8","why":"\#(why)","reason":"no"}}"#
            let decision = try JSONDecoder().decode(InstallCheckDecision.self, from: Data(output.utf8))
            #expect(decision.action.kind == .report)
            let notice = NightlyInstallCheckNotice(decision.notice)
            #expect(notice.title == UpdaterStrings.installCheckStayedTitle)
            let want = why == "storeUnreadable" ? UpdaterStrings.installCheckStoreUnreadable("8", "no") : UpdaterStrings.installCheckNoPassingBuild("8", "no")
            #expect(notice.body == want)
        }
    }

    @Test func aKeepDecodes() throws {
        let decision = try JSONDecoder().decode(InstallCheckDecision.self, from: Data(#"{"action":{"kind":"keep"},"record":null,"pin":null,"notice":null}"#.utf8))
        #expect(decision.action.kind == .keep)
        #expect(decision.notice == nil)
    }

    /// A failed rollback is one notice too: the refused build's own launch shows it, with the
    /// failure, or with "quit before it finished" when the app ended before saying one.
    @Test func aFailedRollBackSaysSoAndHowToRecover() throws {
        let failed = #"{"kind":"rollbackFailed","notice":{"build":"8","target":"7","reason":"no"},"failure":"The kept copy is gone."}"#
        let notice = NightlyInstallCheckNotice(try JSONDecoder().decode(InstallCheckShow.self, from: Data(failed.utf8)))
        #expect(notice.title == UpdaterStrings.installCheckStayedTitle)
        #expect(notice.body == UpdaterStrings.installCheckRollbackFailed("8", "no", "7", "The kept copy is gone."))
        #expect(notice.body.contains("NIGHTLY"))
        let unfinished = #"{"kind":"rollbackFailed","notice":{"build":"8","target":"7","reason":"no"}}"#
        let quit = NightlyInstallCheckNotice(try JSONDecoder().decode(InstallCheckShow.self, from: Data(unfinished.utf8)))
        #expect(quit.body.contains(UpdaterStrings.installCheckRollbackUnfinished))
    }
}
