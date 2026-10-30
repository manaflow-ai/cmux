import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A quit deadline that ends the process while state files still save names them (no content) and
/// records them; the next launch takes the record once, and a lost unsent draft earns a notice (R9
/// review of cmux#28275). No clock decides these tests: the deadline's end is called directly while a
/// save is held.
@Suite(.serialized)
@MainActor
struct AgentPaneStateLossTests {
    @Test func theDeadlineRecordsTheFilesStillSavingAndTheNextLaunchTakesThem() async throws {
        let directory = try AgentPaneStateFileTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let drafts = files.at(directory.appending(path: AgentUnsentDrafts.fileName))
        let release = AgentPaneStateFileTests.holdQueue(drafts)
        defer { release.signal() }
        drafts.write { Data("draft".utf8) }
        let loss = AgentPaneStateLoss(directory: directory)
        let ended = Mutex(false)
        loss.deadlineEnd(files: files, end: { ended.withLock { $0 = true } })()
        #expect(ended.withLock { $0 }, "the deadline's end did not end")
        let names = await loss.take()
        #expect(names == [AgentUnsentDrafts.fileName], "the record named \(names)")
        #expect(AgentPaneStateLoss.notice(for: names) != nil, "a lost unsent draft shows no notice")
        #expect(await loss.take().isEmpty, "the next launch took the record twice")
    }

    @Test func aQuitWithNothingStillSavingRecordsNothing() async throws {
        let directory = try AgentPaneStateFileTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = AgentPaneStateFiles()
        let drafts = files.at(directory.appending(path: AgentUnsentDrafts.fileName))
        drafts.write { Data("draft".utf8) }
        await files.drained()
        let loss = AgentPaneStateLoss(directory: directory)
        loss.deadlineEnd(files: files, end: {})()
        #expect(await loss.take().isEmpty)
    }

    @Test func aLostScrollPlaceShowsNoNotice() {
        #expect(AgentPaneStateLoss.notice(for: [AgentPaneScrollAnchors.fileName]) == nil)
    }
}
