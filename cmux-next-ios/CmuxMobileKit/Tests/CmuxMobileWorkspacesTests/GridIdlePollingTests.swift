#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileWorkspaces

/// Leo 2026-11-14: "I want us to also look at if we can decrease battery drain/ram on iOS app".
/// A workspace grid left on screen with 8 terminal tabs and nothing changing on the Mac asked
/// each terminal for its foreground program (`process-info`) every 2.5 s, only so a close could
/// list running programs, and woke a display link every second to catch up agent cards that had
/// not changed; both kept going while the app was in the background.
@MainActor @Suite struct GridIdlePollingTests {
    /// One `process-info` RPC per terminal per call (`LiveWorkspaceCreation.runningPrograms`).
    @MainActor final class CountingProgramsBackend: WorkspaceCreationBackend {
        var rpcs = 0
        func canCreate(on macID: String) -> Bool { true }
        func options(on macID: String) -> WorkspaceCreationOptions { .basic }
        func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
        func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {}
        func runningPrograms(of tabs: [WorkspaceTab], in workspace: Workspace) async -> [String] {
            rpcs += tabs.filter { $0.kind == .terminal }.count
            return []
        }
    }

    /// Terminal content whose Mac output the test sends.
    @MainActor final class OutputTerminalContent: TerminalTabContent {
        var handler: (@MainActor (String?, String) -> Void)?
        func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView { AnyView(EmptyView()) }
        func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView { AnyView(EmptyView()) }
        func observeOutput(_ owner: AnyObject, _ handler: @escaping @MainActor (String?, String) -> Void) { self.handler = handler }
    }

    struct Grid {
        let terminal: OutputTerminalContent
        let macID: String
        let source: WorkspaceTabsSource
        let backend: CountingProgramsBackend
        let clock: GridTestClock
    }

    /// A workspace of 8 terminal tabs, its grid open and at rest.
    func idleGrid() async -> Grid {
        let store = AppStore.mock(tabMemory: .inMemory())
        let tabs = (1...8).map { WorkspaceTab(id: "term\($0)", kind: .terminal, title: "zsh") }
        let macID = store.workspaces.first?.macID ?? "mac"
        store.workspaces.append(Workspace(id: "ws-eight", macID: macID, title: "Eight", directory: "~", tabs: tabs, lastActivityAt: Date()))
        let backend = CountingProgramsBackend()
        let clock = GridTestClock()
        let terminal = OutputTerminalContent()
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-eight", terminal: terminal,
                                         creator: WorkspaceCreator(store: store, backend: backend), clock: clock)
        source.overviewWillAppear()
        source.overviewVisibilityChanged(true)
        source.overviewIdleChanged(true)
        await settle()
        return Grid(terminal: terminal, macID: macID, source: source, backend: backend, clock: clock)
    }

    func settle() async {
        for _ in 0..<64 { await Task.yield() }
    }

    /// RPCs and card wake-ups over one simulated minute (in 250 ms steps).
    func minute(_ grid: Grid) async -> (rpcs: Int, wakeups: Int) {
        let rpcs = grid.backend.rpcs
        let wakeups = grid.source.followWakeups
        for _ in 0..<240 {
            grid.clock.advance(by: .milliseconds(250))
            await settle()
        }
        return (grid.backend.rpcs - rpcs, grid.source.followWakeups - wakeups)
    }

    @Test func anIdleGridAsksTheMacNothing() async {
        let grid = await idleGrid()
        let (rpcs, wakeups) = await minute(grid)
        print("grid-idle-rpcs: 8 terminal tabs idle on screen: \(rpcs) process-info RPC/min, \(wakeups) card wake-ups/min")
        #expect(rpcs == 0)
        #expect(wakeups == 0)
        grid.source.overviewVisibilityChanged(false)
        grid.clock.stop()
    }

    /// The close prompt still knows a busy terminal: one that drew output is read again
    /// (once per interval), the quiet ones are not.
    @Test func aTerminalThatDrewOutputIsReadAgain() async {
        let grid = await idleGrid()
        let before = grid.backend.rpcs
        grid.terminal.handler?("term3", grid.macID)
        grid.terminal.handler?("term3", grid.macID)
        await settle()
        grid.clock.advance(by: WorkspaceTabsSource.programPrefetchInterval)
        await settle()
        #expect(grid.backend.rpcs - before == 1)
        grid.source.overviewVisibilityChanged(false)
        grid.clock.stop()
    }

    @Test func aBackgroundedGridAsksTheMacNothing() async {
        let grid = await idleGrid()
        grid.source.sceneActiveChanged(false)
        await settle()
        let (rpcs, wakeups) = await minute(grid)
        print("grid-idle-rpcs: 8 terminal tabs, app in background: \(rpcs) process-info RPC/min, \(wakeups) card wake-ups/min")
        #expect(rpcs == 0)
        #expect(wakeups == 0)
        grid.source.overviewVisibilityChanged(false)
        grid.clock.stop()
    }
}

/// A clock that moves only when the test advances it (`LinkTestClock`'s shape).
final class GridTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let lock = NSLock()
    private var instant = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var stopped = false
    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waits = lock.withLock {
                    if stopped || deadline <= instant || Task.isCancelled { return false }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                if !waits {
                    if Task.isCancelled || lock.withLock({ stopped }) { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume() }
                }
            }
        } onCancel: {
            let cancelled = self.lock.withLock { () -> Sleeper? in
                guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return self.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func stop() {
        let pending = lock.withLock {
            stopped = true
            let pending = sleepers
            sleepers.removeAll()
            return pending
        }
        pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            instant = instant.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= instant }
            sleepers.removeAll { $0.deadline <= instant }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}
#endif
