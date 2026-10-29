import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextWakeups
import Foundation
import Testing

/// Feature `crashForwardersAfterStartup`: with it `AppCrashReporting` hands the launch's
/// scheduler to ``CrashForwarders/post(on:)``, so the crash report and panic log forwarders (the
/// DiagnosticReports listing, the panic logs, finding acpmux) are one afterStartup best-effort files-lane
/// post: none of their file work runs while the launch loads, it runs once off main after startup completes
/// (behind the raised best-effort fence), and never after a quit before it. Without it they start at once
/// (``CrashForwarders/start()``, CrashForwardersTests).
@MainActor @Suite(.timeLimit(.minutes(1))) struct CrashForwardersAfterStartupTests {
    @Test func theForwardersRunOffMainOnlyAfterStartupCompletes() async {
        let f = LaunchOrderFixture()
        let scratch = ForwarderScratch()
        defer { scratch.remove() }
        let (seen, report) = AsyncStream.makeStream(of: Bool.self)
        scratch.forwarders { report.yield($0) }.post(on: f.order.startup)
        f.hand.drain()
        let restore = f.order.startup.hold("WindowManager.restore")
        f.complete()
        for _ in 0..<3 { f.fire() }
        let records = f.order.startup.log.records
        #expect(records.map(\.name.description) == ["CrashReporting.forwarders"])
        #expect(records.map(\.destination) == [.lane(.files, .bestEffort)])
        #expect(records.first?.startNanos == nil, "the forwarders started while a visible pane still loaded")
        restore.release(.visiblePaneLoadedIdle)
        f.hand.drain()
        var reports = seen.makeAsyncIterator()
        let onMain = await reports.next()
        #expect(onMain == false, "the forwarders' file work ran on main")
    }

    @Test func aQuitBeforeCompletionNeverRunsTheForwarders() {
        let f = LaunchOrderFixture()
        let scratch = ForwarderScratch()
        defer { scratch.remove() }
        let runs = ForwarderRuns()
        scratch.forwarders { _ in runs.add() }.post(on: f.order.startup)
        f.hand.drain()
        f.order.startup.beginQuit()
        f.complete()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 0)
        #expect(f.order.startup.log.records.first?.startNanos == nil)
    }
}

/// A scratch folder for the forwarders' state and logs.
private struct ForwarderScratch {
    let root = FileManager.default.temporaryDirectory.appending(path: "forwarders-after-startup-\(UUID().uuidString)")

    /// Forwarders over the folder whose acpmux maker calls `searched` (with no acpmux found).
    func forwarders(searched: @escaping @Sendable (Bool) -> Void) -> CrashForwarders {
        let system = SystemCrashForwarder(directory: root.appending(path: "DiagnosticReports", directoryHint: .isDirectory),
                                          stateFile: root.appending(path: "system-state.json"), bundlePath: root.path,
                                          mainExecutable: nil, hostExeRoot: nil, ownRustBinaries: [], artifacts: nil,
                                          capture: { _, _ in })
        let owner = OwnerPanicForwarder(log: root.appending(path: "owner-panics-s.jsonl"),
                                        stateFile: root.appending(path: "owner-state.json"), sends: true, capture: { _ in })
        return CrashForwarders(system: system, ownerPanics: owner) {
            searched(Thread.isMainThread)
            return nil
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// How many times the acpmux maker ran, from any thread.
private nonisolated final class ForwarderRuns: Sendable {
    private let state = Mutex(0)

    var count: Int { state.withLock { $0 } }

    func add() { state.withLock { $0 += 1 } }
}
