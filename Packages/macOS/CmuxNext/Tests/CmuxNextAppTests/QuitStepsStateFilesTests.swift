import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// A quit through QuitCoordinator waits for the agent panes' state files (a new chat's unsent draft)
/// in its save step and again before the engines stop, so a draft queued behind a busy disk is on disk
/// when the quit goes on. The wait holds no thread (QuitStateFilesTests).
@MainActor
@Suite(.serialized)
struct QuitStepsStateFilesTests {
    /// A draft save queued behind a save that holds the file's queue for 1 s (a busy disk; within the
    /// quit's 2 s limit), and a check that it ran.
    static func queuedDraft(_ services: AppServices, in directory: URL) -> (url: URL, written: () -> Bool) {
        let url = directory.appending(path: AgentUnsentDrafts.fileName)
        let file = services.agentPaneStateFiles.at(url)
        let release = QuitStateFilesTests.hold(file)
        file.write { Data("draft".utf8) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { release.signal() }
        return (url, { (try? Data(contentsOf: url)) == Data("draft".utf8) })
    }

    @Test func theSaveStepEndsWithTheQueuedDraftOnDisk() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let draft = Self.queuedDraft(services, in: directory)
        await services.quit.steps().prepareWindows()
        #expect(draft.written(), "the quit's save step returned before the queued draft was on disk")
    }

    @Test func theEnginesStopAfterTheQueuedDraftIsOnDisk() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        var writtenAtEngineStop: Bool?
        let draft = Self.queuedDraft(services, in: directory)
        services.quit.stopEngines = { writtenAtEngineStop = draft.written() }
        await services.quit.steps().stopBrowserEngines()
        #expect(writtenAtEngineStop == true, "the engines began to stop before the queued draft was on disk")
    }
}
