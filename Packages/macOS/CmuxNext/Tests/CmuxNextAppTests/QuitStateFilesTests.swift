import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// The quit's last state-file saves (a new chat's unsent draft, scroll places, the paired phones' list)
/// never block the main thread (rise audit of cmux#27749 and #25535): the forced quit arms its deadline
/// before it waits for them, and the normal quit awaits them with no blocking allowance.
@MainActor
@Suite(.serialized)
struct QuitStateFilesTests {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "quit-state-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Holds the file's queue in a first save until `release`, as a busy disk does.
    static func hold(_ file: AgentPaneStateFile) -> DispatchSemaphore {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        file.write {
            started.signal()
            // concurrency-allow: test only; holds the file queue (a busy disk); a safety net of 60 s
            _ = release.wait(timeout: .now() + 60)
            return Data("held".utf8)
        }
        // concurrency-allow: test only; the first save is running
        _ = started.wait(timeout: .now() + 10)
        return release
    }

    /// A second quit signal with a draft save queued behind a busy disk: the 160 ms deadline is armed at
    /// once (before, `prepare` waited up to 2 s on the saves under a blocking allowance), and the exit
    /// still ends after the draft reached the disk when the disk answers within the deadline.
    @Test func theForcedQuitArmsItsDeadlineBeforeItWaitsForTheStateFiles() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let url = directory.appending(path: AgentUnsentDrafts.fileName)
        let release = Self.hold(services.agentPaneStateFiles.at(url))
        services.agentPaneStateFiles.at(url).write { Data("draft".utf8) }
        let started = ContinuousClock.now
        var armedAfter: Duration?
        var onDiskAtEnd: Data?
        let exit = AppDelegate.secondSignalExit({ services },
                                               armDeadline: { _ in armedAfter = ContinuousClock.now - started },
                                               end: { onDiskAtEnd = try? Data(contentsOf: url) })
        let ending = exit.start()
        let armed = try #require(armedAfter, "start() returned with no deadline armed")
        #expect(armed < .milliseconds(500), "the deadline was armed \(armed) after the start: a wait on the state files came first")
        release.signal()
        await ending?.value
        #expect(onDiskAtEnd == Data("draft".utf8), "the forced quit ended before the queued draft save")
    }

    /// The quit (QuitCoordinator's save steps) awaits a draft save queued behind a busy disk: the main
    /// actor keeps running meanwhile, and the draft is on disk when the wait returns.
    @Test func theQuitAwaitsAQueuedDraftWithoutBlockingTheMainThread() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let url = directory.appending(path: AgentUnsentDrafts.fileName)
        let file = services.agentPaneStateFiles.at(url)
        let release = Self.hold(file)
        file.write { Data("draft".utf8) }
        let quit = Task { await services.stateFilesDrained() }
        let started = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(200))
        let waited = ContinuousClock.now - started
        #expect(waited < .seconds(1), "the main actor was held \(waited) while the save was queued")
        release.signal()
        await quit.value
        #expect((try? Data(contentsOf: url)) == Data("draft".utf8), "the quit's wait returned before the queued draft save")
    }
}
