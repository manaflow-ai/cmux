import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextControl
import CmuxNextMobile
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

    /// The app's services with `gate`'s state files, a quit deadline that never ends the test process,
    /// and no key window.
    static func services(_ gate: DrainGate) -> AppServices {
        // The quit steps read `NSApp` (the key window, whether the app is active): make the app object
        // first, as the other AppServices tests do. The root fix of those reads is
        // fix/arch-rise-appservices-no-nsapp-trap.
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneStateFiles: gate.files)
        // No window is key in a test process.
        services.keyWindowSource = { nil }
        services.quit.deadline = QuitDeadline(reason: "a quit test", end: {})
        return services
    }

    /// A new chat's draft save for `directory` queued behind `gate`'s held save (a busy disk); the
    /// result says whether the draft is on disk.
    static func queueDraft(in directory: URL, gate: DrainGate) -> () -> Bool {
        let url = directory.appending(path: AgentUnsentDrafts.fileName)
        let file = gate.files.at(url)
        gate.hold(file)
        file.write { Data("draft".utf8) }
        return { (try? Data(contentsOf: url)) == Data("draft".utf8) }
    }

    /// A second quit signal with a draft save queued behind a busy disk: the 160 ms deadline is armed
    /// before any wait on the state files (before, `prepare` flushed them under a blocking allowance
    /// first), and the exit ends after the draft reached the disk.
    @Test func theForcedQuitArmsItsDeadlineBeforeItWaitsForTheStateFiles() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let services = Self.services(gate)
        let written = Self.queueDraft(in: directory, gate: gate)
        var onDiskAtEnd: Bool?
        let exit = AppDelegate.secondSignalExit({ services },
                                                armDeadline: { _ in gate.log("deadline armed") },
                                                end: { onDiskAtEnd = written() })
        await exit.start()?.value
        #expect(gate.events() == ["deadline armed", "drain began"],
                "the forced quit's order was \(gate.events()); the deadline must be armed before the state files are awaited")
        #expect(onDiskAtEnd == true, "the forced quit ended before the queued draft save")
    }

    /// The quit's wait holds no thread: the main actor lets the held save go once the drain began, so a
    /// wait that blocked the main thread would never end (the time limit fails the test).
    @Test(.timeLimit(.minutes(1)))
    func theQuitAwaitsAQueuedDraftWithoutBlockingTheMainThread() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate(releasesOnDrain: false)
        defer { gate.releaseHeldSave() }
        let services = Self.services(gate)
        let written = Self.queueDraft(in: directory, gate: gate)
        let quit = Task { await services.stateFilesDrained() }
        await gate.drainBegan()
        gate.releaseHeldSave()
        await quit.value
        #expect(written(), "the quit's wait returned before the queued draft save")
    }

    /// The loss record names the paired phones' list by the file's own name.
    @Test func theLossRecordNamesThePairedListByItsFileName() {
        #expect(AgentPaneStateLoss.pairedPhonesFileName == MobileHostPairedDevicesFile.fileName)
    }
}

/// A save held on a file's queue (a busy disk) that only the start of a drain of the files lets go
/// (``AgentPaneStateFiles/init(drainBegan:)``), and the order of the quit's steps around it.
nonisolated final class DrainGate: Sendable {
    private let release: DispatchSemaphore
    private let began: FirstOutcome<Bool>
    private let state: DrainGateState
    let files: AgentPaneStateFiles

    /// - Parameter releasesOnDrain: A drain that begins while a save is held lets it go; false leaves
    ///   that to the test.
    init(releasesOnDrain: Bool = true) {
        let release = DispatchSemaphore(value: 0), began = FirstOutcome<Bool>(), state = DrainGateState()
        (self.release, self.began, self.state) = (release, began, state)
        files = AgentPaneStateFiles(drainBegan: {
            state.log("drain began")
            began.resolve(true)
            if releasesOnDrain, state.endHold() { release.signal() }
        })
    }

    /// Holds `file`'s queue in a save until a drain begins, so the saves after it wait.
    func hold(_ file: AgentPaneStateFile) {
        let started = DispatchSemaphore(value: 0)
        let release = release
        state.beginHold()
        file.write {
            started.signal()
            // concurrency-allow: test only; holds the file queue until a drain begins (or the test ends)
            release.wait()
            return Data("held".utf8)
        }
        // concurrency-allow: test only; the held save is running
        _ = started.wait(timeout: .now() + 10)
    }

    /// Lets a held save go (the test's own release, and its end); nothing when none is held.
    func releaseHeldSave() {
        if state.endHold() { release.signal() }
    }

    func log(_ event: String) {
        state.log(event)
    }

    func events() -> [String] {
        state.events()
    }

    /// Returns once a drain of the files began.
    func drainBegan() async {
        _ = await began.value()
    }
}

/// Whether a ``DrainGate`` holds a save, and the quit steps' order around it, from any thread.
nonisolated final class DrainGateState: Sendable {
    private let state = Mutex<(held: Bool, events: [String])>((false, []))

    func beginHold() {
        state.withLock { $0.held = true }
    }

    /// Ends the hold; whether one was held.
    func endHold() -> Bool {
        state.withLock { state in
            defer { state.held = false }
            return state.held
        }
    }

    func log(_ event: String) {
        state.withLock { $0.events.append(event) }
    }

    func events() -> [String] {
        state.withLock { $0.events }
    }
}
