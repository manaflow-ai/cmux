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
        let refused = try Self.json(InstallCheckRequest(build: "8", result: .refused("transport.intent_invalid"), kept: kept))
        #expect(refused["nightly"] as? Bool == true)
        #expect(refused["build"] as? String == "8")
        #expect(refused["canary"] as? [String: String] == ["result": "refused", "reason": "transport.intent_invalid"])
        #expect((refused["kept"] as? [[String: Any]])?.first?["readsStore"] as? Bool == true)
        #expect(try Self.json(InstallCheckRequest(build: "8", result: .passed, kept: []))["canary"] as? [String: String] == ["result": "passed"])
        #expect(try Self.json(InstallCheckRequest(build: "8", result: .inconclusive("timeout"), kept: []))["canary"] as? [String: String] == ["result": "inconclusive"])
    }

    @Test func aRollBackDecodesAndReadsAsRolledBack() throws {
        let output = #"{"action":{"kind":"rollBack","to":"7"},"record":{"build":"8","result":"refused"},"pin":"8","notice":{"build":"8","target":"7","reason":"no"}}"#
        let decision = try JSONDecoder().decode(InstallCheckDecision.self, from: Data(output.utf8))
        #expect(decision.action == .init(kind: .rollBack, to: "7", why: nil))
        #expect(decision.pin == "8")
        let notice = NightlyInstallCheckNotice(decision.notice, rolledBack: true)
        #expect(notice.title.contains("7"))
        #expect(notice.body.contains("8") && notice.body.contains("7") && notice.body.contains("no"))
    }

    @Test func aReportDecodesAndReadsAsStayed() throws {
        for why in ["noPassingBuild", "storeUnreadable"] {
            let output = #"{"action":{"kind":"report","why":"\#(why)"},"record":{"build":"8","result":"refused"},"pin":"8","notice":{"build":"8","why":"\#(why)","reason":"no"}}"#
            let decision = try JSONDecoder().decode(InstallCheckDecision.self, from: Data(output.utf8))
            #expect(decision.action.kind == .report)
            let notice = NightlyInstallCheckNotice(decision.notice, rolledBack: false)
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

    @Test func aFailedRollBackSaysSoAndHowToRecover() {
        let notice = NightlyInstallCheckNotice.rollbackFailed(build: "8", reason: "no", failure: "The kept copy is gone.")
        #expect(notice.body.contains("The kept copy is gone."))
        #expect(notice.body.contains("NIGHTLY"))
    }
}
