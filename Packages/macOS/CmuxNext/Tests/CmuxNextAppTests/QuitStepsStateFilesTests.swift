import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// A quit through QuitCoordinator waits for the agent panes' state files (a new chat's unsent draft)
/// once its deadline is armed: before the engines close, and again after it, so a draft saved while a
/// page closes is on disk when the quit ends (R9 review of cmux#28275). The wait holds no thread
/// (QuitStateFilesTests).
///
/// No clock decides these tests: a draft waits behind a held save that only the start of a drain of
/// the files lets go (``DrainGate``), so a step that never drains never writes the draft.
@MainActor
@Suite(.serialized)
struct QuitStepsStateFilesTests {
    @Test func theEnginesCloseAfterTheQueuedDraftIsOnDisk() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let services = QuitStateFilesTests.services(gate)
        let written = QuitStateFilesTests.queueDraft(in: directory, gate: gate)
        var writtenAtClose: Bool?
        services.quit.closeEngines = { writtenAtClose = written() }
        await services.quit.quitSteps(.keep).stopBrowserEngines()
        #expect(gate.events() == ["drain began", "drain began"], "the engine stop step awaited the state files \(gate.events().count) times")
        #expect(writtenAtClose == true, "the engines began to close before the queued draft was on disk")
    }

    @Test func aDraftSavedWhileTheEnginesCloseIsOnDiskWhenTheQuitEnds() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let services = QuitStateFilesTests.services(gate)
        var written: (() -> Bool)?
        // A page that closes saves its draft (the composer's page-hide flush).
        services.quit.closeEngines = { written = QuitStateFilesTests.queueDraft(in: directory, gate: gate) }
        await services.quit.quitSteps(.keep).stopBrowserEngines()
        #expect(gate.events() == ["drain began", "drain began"], "the engine stop step awaited the state files \(gate.events().count) times")
        #expect(written?() == true, "the quit ended before the draft saved while the engines closed was on disk")
    }
}
