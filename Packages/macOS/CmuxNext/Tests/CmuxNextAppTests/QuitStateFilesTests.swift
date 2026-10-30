import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// The quit's last state-file saves (a new chat's unsent draft, scroll places, the paired phones' list)
/// never block the main thread (rise audit of cmux#27749 and #25535): the forced quit arms its deadline
/// before it waits for them, and the quit's wait holds no thread.
///
/// No clock decides these tests: a draft save waits behind a held save that only the start of a drain
/// of the files (``DrainGate``) lets go, so a step that never drains never writes the draft.
@MainActor
@Suite(.serialized)
struct QuitStateFilesTests {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "quit-state-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The app's services with `gate`'s state files, and a new chat's draft save for `directory` queued
    /// behind `gate`'s held save; `written()` says whether the draft is on disk.
    static func queuedDraft(in directory: URL, gate: DrainGate) -> (services: AppServices, written: () -> Bool) {
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneStateFiles: gate.files)
        // No app object in this test process (`NSApp` is nil): the quit steps ask for the key window.
        services.keyWindowSource = { nil }
        let url = directory.appending(path: AgentUnsentDrafts.fileName)
        let file = gate.files.at(url)
        gate.hold(file)
        file.write { Data("draft".utf8) }
        return (services, { (try? Data(contentsOf: url)) == Data("draft".utf8) })
    }

    /// A second quit signal with a draft save queued behind a busy disk: the 160 ms deadline is armed
    /// before any wait on the state files (before, `prepare` flushed them under a blocking allowance
    /// first), and the exit ends after the draft reached the disk.
    @Test func theForcedQuitArmsItsDeadlineBeforeItWaitsForTheStateFiles() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let draft = Self.queuedDraft(in: directory, gate: gate)
        var onDiskAtEnd: Bool?
        let exit = AppDelegate.secondSignalExit({ draft.services },
                                                armDeadline: { _ in gate.log("deadline armed") },
                                                end: { onDiskAtEnd = draft.written() })
        await exit.start()?.value
        #expect(gate.events() == ["deadline armed", "drain began"],
                "the forced quit's order was \(gate.events()); the deadline must be armed before the state files are awaited")
        #expect(onDiskAtEnd == true, "the forced quit ended before the queued draft save")
    }

    /// The quit's wait (QuitCoordinator's save steps) holds no thread: the held save is let go by the
    /// main actor once the drain began, so a wait that blocked the main thread would reach its limit
    /// with the draft still queued.
    @Test func theQuitAwaitsAQueuedDraftWithoutBlockingTheMainThread() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate(releasesOnDrain: false)
        defer { gate.releaseHeldSave() }
        let draft = Self.queuedDraft(in: directory, gate: gate)
        let quit = Task { await draft.services.stateFilesDrained() }
        await gate.drainBegan()
        gate.releaseHeldSave()
        #expect(await quit.value, "the quit's wait reached its limit: the main actor could not run while it waited")
        #expect(draft.written(), "the quit's wait returned before the queued draft save")
    }
}

/// A save held on a file's queue (a busy disk) that only the start of a drain of the files lets go
/// (``AgentPaneStateFiles/init(drainBegan:)``), and the order of the quit's steps around it.
nonisolated final class DrainGate: Sendable {
    private let release: DispatchSemaphore
    private let began: FirstOutcome<Bool>
    private let order: DrainGateLog
    let files: AgentPaneStateFiles

    /// - Parameter releasesOnDrain: Lets the held save go as the drain begins; false leaves it to the test.
    init(releasesOnDrain: Bool = true) {
        let release = DispatchSemaphore(value: 0), began = FirstOutcome<Bool>(), order = DrainGateLog()
        (self.release, self.began, self.order) = (release, began, order)
        files = AgentPaneStateFiles(drainBegan: {
            order.append("drain began")
            began.resolve(true)
            if releasesOnDrain { release.signal() }
        })
    }

    /// Holds `file`'s queue in a save until the drain begins, so the saves after it wait.
    func hold(_ file: AgentPaneStateFile) {
        let started = DispatchSemaphore(value: 0)
        let release = release
        file.write {
            started.signal()
            // concurrency-allow: test only; holds the file queue until a drain begins (or the test ends)
            release.wait()
            return Data("held".utf8)
        }
        // concurrency-allow: test only; the held save is running
        _ = started.wait(timeout: .now() + 10)
    }

    /// Lets the held save go (the test's own release, and its end).
    func releaseHeldSave() {
        release.signal()
    }

    func log(_ event: String) {
        order.append(event)
    }

    func events() -> [String] {
        order.events()
    }

    /// Returns once a drain of the files began.
    func drainBegan() async {
        _ = await began.value()
    }
}

/// The quit steps' order around a ``DrainGate``, from any thread.
nonisolated final class DrainGateLog: Sendable {
    private let order = Mutex<[String]>([])

    func append(_ event: String) {
        order.withLock { $0.append(event) }
    }

    func events() -> [String] {
        order.withLock { $0 }
    }
}
