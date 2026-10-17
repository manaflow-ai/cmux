import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

/// Startup-burst coverage for #21260: five restored agent terminals and a
/// sixth admitted terminal must not open their working directories inside the
/// synchronous main-actor creation call.
@MainActor
@Suite
struct TerminalSurfaceWorkingDirectoryPreflightTests {
    @Test
    func startupBurstDefersNativeCreationUntilWorkingDirectoryOpens() {
        let restored = (0..<5).map { index in
            makeBurstSurface(
                workingDirectory: "/tmp/cmux-burst-restored-\(index)",
                runtimeSpawnPolicy: .pacedSessionRestore
            )
        }
        let admitted = makeBurstSurface(
            workingDirectory: "/tmp/cmux-burst-admitted",
            runtimeSpawnPolicy: .immediate
        )

        for entry in restored {
            entry.surface.createSurface(for: entry.view, source: .scheduledRestore)
        }
        admitted.surface.createSurface(for: admitted.view)

        // Native creation (and Ghostty's main-thread working-directory open)
        // must wait for an off-main open instead of running in this call.
        for entry in restored + [admitted] {
            #expect(entry.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        }
    }

    @Test
    func stalledRestoredDirectoriesDoNotHoldBackAdmittedSurface() async {
        let stalled = WorkingDirectoryOpenGate()
        let stalledFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installAgentCommandShims: { _, _, _ in nil },
            isExecutableFile: { _ in false },
            prepareWorkingDirectory: { path in await stalled.open(path) }
        )
        let restored = (0..<5).map { index in
            makeBurstSurface(
                workingDirectory: "/tmp/cmux-burst-restored-\(index)",
                runtimeSpawnPolicy: .pacedSessionRestore,
                runtimeFilesystem: stalledFilesystem
            )
        }
        let admitted = makeBurstSurface(
            workingDirectory: "/tmp/cmux-burst-admitted",
            runtimeSpawnPolicy: .immediate
        )

        for entry in restored {
            entry.surface.createSurface(for: entry.view, source: .scheduledRestore)
            // Duplicate readiness callbacks coalesce onto the one open.
            entry.surface.createSurface(for: entry.view, source: .inputDemand)
        }
        await stalled.waitForOpenCount(5)
        admitted.surface.createSurface(for: admitted.view)
        await admitted.surface.runtimeWorkingDirectoryPreflightTask?.value

        // The sixth surface reaches native creation while all five restored
        // directory opens are still blocked.
        #expect(admitted.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        for entry in restored {
            #expect(entry.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        }

        let preflightTasks = restored.map { $0.surface.runtimeWorkingDirectoryPreflightTask }
        await stalled.releaseAll()
        for task in preflightTasks {
            await task?.value
        }

        #expect(await stalled.openCount() == 5)
        for entry in restored {
            #expect(entry.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        }
    }

    @Test
    func teardownWithdrawsCreationPendingOnWorkingDirectoryOpen() async {
        let stalled = WorkingDirectoryOpenGate()
        let entry = makeBurstSurface(
            workingDirectory: "/tmp/cmux-burst-closed",
            runtimeSpawnPolicy: .immediate,
            runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                agentCommandShimRootDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
                installAgentCommandShims: { _, _, _ in nil },
                isExecutableFile: { _ in false },
                prepareWorkingDirectory: { path in await stalled.open(path) }
            )
        )

        entry.surface.createSurface(for: entry.view)
        await stalled.waitForOpenCount(1)
        let preflightTask = entry.surface.runtimeWorkingDirectoryPreflightTask
        entry.surface.teardownSurface()
        await stalled.releaseAll()
        await preflightTask?.value

        #expect(entry.surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
    }

    private func makeBurstSurface(
        workingDirectory: String,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installAgentCommandShims: { _, _, _ in nil },
            isExecutableFile: { _ in false }
        )
    ) -> BurstSurface {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let nativeView = FakeTerminalSurfaceNativeView(frame: frame)
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(paneHost)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: workingDirectory,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: RecordingRestoreSpawnScheduler(),
                runtimeFilesystem: runtimeFilesystem,
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        surface.agentCommandShimInstallCompleted = true
        return BurstSurface(surface: surface, view: nativeView, window: window)
    }
}

@MainActor
private struct BurstSurface {
    let surface: TerminalSurface
    let view: FakeTerminalSurfaceNativeView
    let window: NSWindow
}

/// Holds working-directory opens until the test releases them, modeling a
/// filesystem stalled by a burst of starting agents.
private actor WorkingDirectoryOpenGate {
    private var openedPaths: [String] = []
    private var pendingOpens: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isReleased = false

    func open(_ path: String) async {
        openedPaths.append(path)
        let ready = countWaiters.filter { openedPaths.count >= $0.count }
        countWaiters.removeAll { openedPaths.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { pendingOpens.append($0) }
    }

    func waitForOpenCount(_ count: Int) async {
        guard openedPaths.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func releaseAll() {
        isReleased = true
        let opens = pendingOpens
        pendingOpens.removeAll()
        for open in opens {
            open.resume()
        }
    }

    func openCount() -> Int {
        openedPaths.count
    }
}
