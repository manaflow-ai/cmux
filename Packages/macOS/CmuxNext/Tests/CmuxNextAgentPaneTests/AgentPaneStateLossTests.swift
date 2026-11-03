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
        #expect(AgentPaneStateLoss.notices(for: names, pairedSealCleared: false).count == 1, "a lost unsent draft shows no notice")
        #expect(await loss.take() == names, "a second read in one launch got other names")
        #expect(await AgentPaneStateLoss(directory: directory).take().isEmpty, "the launch after it took the record again")
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

    /// The paired phones' list a deadline cut off is named beside the agent panes' files, and the next
    /// launch tells the person to pair again only when it cleared the seal.
    @Test func aCutOffPairedListIsRecordedAndTold() async throws {
        let directory = try AgentPaneStateFileTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loss = AgentPaneStateLoss(directory: directory)
        loss.deadlineEnd(files: AgentPaneStateFiles(), alsoCutOff: { [AgentPaneStateLoss.pairedPhonesFileName] }, end: {})()
        let names = await loss.take()
        #expect(names == [AgentPaneStateLoss.pairedPhonesFileName], "the record named \(names)")
        #expect(AgentPaneStateLoss.notices(for: names, pairedSealCleared: true).count == 1, "a cleared paired seal shows no notice")
        #expect(AgentPaneStateLoss.notices(for: names, pairedSealCleared: false).isEmpty, "the pair-again notice shows while the seal still stands")
    }

    /// The paired list's check (on its own queue) and the notice read the record once between them, in
    /// either order, so neither misses it.
    @Test func thePairedCheckAndTheNoticeShareOneReadOfTheRecord() async throws {
        let directory = try AgentPaneStateFileTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        AgentPaneStateLoss(directory: directory).deadlineEnd(files: AgentPaneStateFiles(), alsoCutOff: { [AgentPaneStateLoss.pairedPhonesFileName] }, end: {})()
        let launch = AgentPaneStateLoss(directory: directory)
        let names = await launch.take()
        #expect(names == [AgentPaneStateLoss.pairedPhonesFileName])
        #expect(launch.lastQuitCutOffPairedPhones(), "the paired check missed the record the notice read first")
    }

    /// The record's names as they are on disk (no reader object, which would change it).
    static func onDisk(_ directory: URL) -> [String] {
        (try? Data(contentsOf: directory.appending(path: AgentPaneStateLoss.fileName)))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// The record may be the only copy of a cut-off paired save: after the launch reads it, it keeps
    /// naming the paired list (and only it: a lost draft is told once), a quit deadline in that run keeps
    /// the name beside its own, and only the paired list's settling removes it.
    @Test func theRecordKeepsNamingACutOffPairedListUntilItIsSettled() async throws {
        let directory = try AgentPaneStateFileTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = AgentUnsentDrafts.fileName, paired = AgentPaneStateLoss.pairedPhonesFileName
        AgentPaneStateLoss(directory: directory).deadlineEnd(files: AgentPaneStateFiles(), alsoCutOff: { [drafts, paired] }, end: {})()
        let launch = AgentPaneStateLoss(directory: directory)
        #expect(await launch.take() == [drafts, paired])
        #expect(Self.onDisk(directory) == [paired], "after the launch read it, the record names \(Self.onDisk(directory))")
        launch.deadlineEnd(files: AgentPaneStateFiles(), alsoCutOff: { [drafts] }, end: {})()
        #expect(Self.onDisk(directory) == [drafts, paired], "a quit deadline in that run dropped the paired name: \(Self.onDisk(directory))")
        launch.pairedCutOffSettled()
        #expect(Self.onDisk(directory) == [drafts], "settling left the record as \(Self.onDisk(directory))")
    }

    @Test func aLostScrollPlaceShowsNoNotice() {
        #expect(AgentPaneStateLoss.notices(for: [AgentPaneScrollAnchors.fileName], pairedSealCleared: false).isEmpty)
    }
}
