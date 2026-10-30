import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// A quit through QuitCoordinator waits for the agent panes' state files (a new chat's unsent draft)
/// in its save step and again before the engines stop, so a draft queued behind a busy disk is on disk
/// when the quit goes on. The wait holds no thread (QuitStateFilesTests).
///
/// No clock decides these tests: the draft waits behind a held save that only the start of a drain of
/// the files lets go (``DrainGate``), so a step that never drains never writes the draft.
@MainActor
@Suite(.serialized)
struct QuitStepsStateFilesTests {
    @Test func theSaveStepEndsWithTheQueuedDraftOnDisk() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let draft = QuitStateFilesTests.queuedDraft(in: directory, gate: gate)
        await draft.services.quit.steps().prepareWindows()
        #expect(gate.events() == ["drain began"], "the quit's save step never awaited the state files")
        #expect(draft.written(), "the quit's save step returned before the queued draft was on disk")
    }

    @Test func theEnginesStopAfterTheQueuedDraftIsOnDisk() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let draft = QuitStateFilesTests.queuedDraft(in: directory, gate: gate)
        var writtenAtEngineStop: Bool?
        draft.services.quit.stopEngines = { writtenAtEngineStop = draft.written() }
        await draft.services.quit.steps().stopBrowserEngines()
        #expect(gate.events() == ["drain began"], "the engine stop step never awaited the state files")
        #expect(writtenAtEngineStop == true, "the engines began to stop before the queued draft was on disk")
    }
}
