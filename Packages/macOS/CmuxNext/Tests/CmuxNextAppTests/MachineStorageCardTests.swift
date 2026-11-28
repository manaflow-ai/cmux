import CmuxNextAgentPane
import CmuxNextDesign
@testable import CmuxNextServer
import Foundation
import Testing

/// Storage on This Mac reads acpmux's worktree cleanup report as the daemon writes it
/// (`_acpmux/worktree/report`, cmux-worktree-care `pass::Report` with `autoCleanup` and `at`) and
/// shows the disk, what cleanup could free, the worktrees it keeps and would clean up, the last
/// cleanup and whether automatic cleanup is on; Clean up now runs `_acpmux/worktree/clean`, waits
/// disabled while a pass runs, then shows what it freed. Leo: "if it's been a while, free the
/// disk ... sell machines that just clean stuff up, they just work."
@MainActor @Suite(.serialized) struct MachineStorageCardTests {
    static func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/worktree-care/report.json")
        return try Data(contentsOf: url)
    }

    /// A pass that acted (Clean up now's answer): 3 GiB freed.
    static let cleanAnswer = Data(#"""
    {"disk":{"total":994662584320,"available":123255349248},"pressure":"normal","applied":true,
     "items":[{"path":"/w/old-spike","repository":"/r","branch":"cmux/old-spike","verdict":{"action":"reclaim","reason":"merged"},
               "outcome":{"ok":true,"freed":3221225472,"archive":"arc-2"}}],
     "freed":3221225472,"reclaimable":0,"errors":[],"expired":[],"autoCleanup":true,"at":1795000100000}
    """#.utf8)

    static func line(_ label: String, _ value: String) -> String { MachineStorageStrings.line(label, value) }

    /// The report JSON as the daemon sends it becomes the card's words: the disk from the
    /// report, the reclaimable bytes, one worktree kept and two to clean up, the last pass that
    /// acted (`last.at`), automatic cleanup on, and an enabled Clean up now (Return) beside Done.
    @Test func aRealReportReadsAsTheCardsLines() throws {
        let reply = try JSONDecoder().decode(WorktreeCareReportReply.self, from: Self.fixture())
        var state = MachineStorageState()
        state.measured(reply)
        let spec = MachineStorageCard.spec(state)
        #expect(spec.title == MachineStorageStrings.title)
        #expect(spec.lines.contains(Self.line(MachineStorageStrings.disk, MachineStorageStrings.free(
            MachineStorageCard.bytes(120_034_123_776), of: MachineStorageCard.bytes(994_662_584_320)))))
        #expect(spec.lines.contains(Self.line(MachineStorageStrings.reclaimable, MachineStorageCard.bytes(5_368_709_120))))
        #expect(spec.lines.contains(Self.line(MachineStorageStrings.kept, 1.formatted())))
        #expect(spec.lines.contains(Self.line(MachineStorageStrings.toClean, 2.formatted())))
        #expect(state.lastCleanup == Date(timeIntervalSince1970: 1_794_996_400))
        #expect(!spec.lines.contains(Self.line(MachineStorageStrings.lastCleanup, MachineStorageStrings.noCleanupYet)))
        #expect(spec.lines.contains(Self.line(MachineStorageStrings.automatic, MachineStorageStrings.on)))
        #expect(spec.buttons.map(\.id) == [MachineStorageCard.doneID, MachineStorageCard.cleanID])
        #expect(spec.defaultButton?.id == MachineStorageCard.cleanID)
        #expect(spec.cancelButton?.id == MachineStorageCard.doneID)
    }

    /// No pass that acted since the daemon started (`last: null`) and automatic cleanup off: the
    /// card says so rather than leaving the lines out.
    @Test func noLastPassAndAutomaticOffAreSaid() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Self.fixture()) as? [String: Any])
        var report = try #require(object["report"] as? [String: Any])
        report["autoCleanup"] = false
        object["report"] = report
        object["last"] = NSNull()
        var state = MachineStorageState()
        state.measured(try JSONDecoder().decode(WorktreeCareReportReply.self, from: JSONSerialization.data(withJSONObject: object)))
        let spec = MachineStorageCard.spec(state)
        #expect(spec.lines.contains(Self.line(MachineStorageStrings.lastCleanup, MachineStorageStrings.noCleanupYet)))
        #expect(spec.lines.contains(Self.line(MachineStorageStrings.automatic, MachineStorageStrings.off)))
    }

    /// The card's whole flow over a stand-in daemon: opening measures (Clean up now disabled
    /// until the answer), Clean up now calls clean once, stays disabled while it runs, then shows
    /// what it freed and measures again.
    @Test func cleanUpNowRunsCleanShowsFreedAndMeasuresAgain() async throws {
        let calls = Calls()
        let fixture = try Self.fixture()
        let popover = MachineStoragePopover(source: {
            MachineStoragePopover.Source(report: { calls.reports += 1; return fixture },
                                         clean: { calls.cleans += 1; return Self.cleanAnswer },
                                         refusal: Self.refusal, volume: { nil })
        })
        popover.open(over: nil)
        defer { popover.close() }
        #expect(popover.state.phase == .measuring)
        #expect(MachineStorageCard.spec(popover.state).buttons.last?.isEnabled == false, "no Clean up now while a pass runs")
        await popover.settle()
        #expect(calls.reports == 1)
        #expect(MachineStorageCard.spec(popover.state).buttons.last?.isEnabled == true)

        popover.pressed(MachineStorageCard.cleanID)
        #expect(popover.state.phase == .cleaning)
        popover.pressed(MachineStorageCard.cleanID)
        await popover.settle()
        #expect(calls.cleans == 1, "a second press while cleaning starts nothing")
        #expect(calls.reports == 2, "the card measures again after a cleanup")
        #expect(popover.state.phase == .idle)
        let spec = MachineStorageCard.spec(popover.state)
        #expect(spec.fields.contains(.note(MachineStorageStrings.freed(MachineStorageCard.bytes(3_221_225_472)), danger: false)))
        #expect(popover.state.lastCleanup == Date(timeIntervalSince1970: 1_795_000_100))
    }

    /// A refusal (an automatic pass already running) shows in the daemon's words, and Clean up
    /// now can be pressed again.
    @Test func aRefusalShowsTheDaemonsWords() async throws {
        let message = "a worktree cleanup pass or report is already running"
        let popover = MachineStoragePopover(source: {
            MachineStoragePopover.Source(report: { throw AcpmuxRPCError(code: -32603, message: message) },
                                         clean: { Self.cleanAnswer }, refusal: Self.refusal, volume: { nil })
        })
        popover.open(over: nil)
        defer { popover.close() }
        await popover.settle()
        let spec = MachineStorageCard.spec(popover.state)
        #expect(spec.error == message)
        #expect(spec.buttons.last?.isEnabled == true)
    }

    /// No acpmux (a mock agent host): the card says the service did not answer.
    @Test func noDaemonSaysTheServiceDidNotAnswer() {
        let popover = MachineStoragePopover(source: { nil })
        popover.open(over: nil)
        defer { popover.close() }
        #expect(MachineStorageCard.spec(popover.state).error == MachineStorageStrings.unreachable)
    }

    /// The App's mapping: the daemon's words for a refusal it answered (``AcpmuxRPCError``).
    static func refusal(_ error: any Error) -> String? { (error as? AcpmuxRPCError)?.message }

    @MainActor final class Calls {
        var reports = 0
        var cleans = 0
    }
}
