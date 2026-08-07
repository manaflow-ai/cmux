import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

private final class RemoteResetFreedSurfaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var address: UInt?

    func store(_ surface: ghostty_surface_t) {
        lock.lock()
        address = UInt(bitPattern: surface)
        lock.unlock()
    }

    func matches(_ surface: ghostty_surface_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return address == UInt(bitPattern: surface)
    }
}

private final class RemoteResetFailureReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?

    func store(_ reason: String?) {
        lock.lock()
        self.reason = reason
        lock.unlock()
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

@MainActor
@Suite(.serialized)
struct TerminalSurfaceRemoteResetTests {
    @Test func coldManualSurfaceKeepsTheAuthoritativeGridAndReplayTogether() {
        let surface = makeSurface(ioMode: .manualMirror)
        defer {
            surface.closeHeadlessStartupWindowIfNeeded()
            surface.releaseSurfaceForTesting()
        }

        let replay = Data("prompt> ".utf8)
        #expect(surface.resetRemoteOutput(columns: 132, rows: 44, replay: replay))
        #expect(surface.pendingRemoteGrid?.columns == 132)
        #expect(surface.pendingRemoteGrid?.rows == 44)
        #expect(surface.pendingRemoteOutput == replay)

        surface.processRemoteOutput(Data("echo ready\r\n".utf8))
        #expect(surface.pendingRemoteOutput == replay + Data("echo ready\r\n".utf8))
    }

    @Test func coldManualSurfaceNeverTruncatesAnAuthoritativeReplayPrefix() {
        let surface = makeSurface(ioMode: .manualMirror)
        defer {
            surface.closeHeadlessStartupWindowIfNeeded()
            surface.releaseSurfaceForTesting()
        }

        let replay = Data(count: surface.maxPendingRemoteOutputBytes - 2)
        #expect(surface.resetRemoteOutput(columns: 80, rows: 24, replay: replay))
        surface.processRemoteOutput(Data([1, 2, 3]))

        #expect(surface.pendingRemoteOutput == replay)
    }

    @Test func resizeAfterColdResetRemainsOrderedAfterTheSnapshotReplay() {
        let surface = makeSurface(ioMode: .manualMirror)
        defer {
            surface.closeHeadlessStartupWindowIfNeeded()
            surface.releaseSurfaceForTesting()
        }

        #expect(surface.resetRemoteOutput(
            columns: 132,
            rows: 44,
            replay: Data("snapshot".utf8)
        ))
        surface.applyRemoteGrid(columns: 80, rows: 24)

        #expect(surface.pendingRemoteEventKindsForTesting == [
            "reset:132x44:8",
            "resize:80x24",
        ])
    }

    @Test func resetRejectsNonManualSurfacesAndOversizedSnapshotsWithoutMutation() {
        let execSurface = makeSurface(ioMode: .exec)
        defer { execSurface.releaseSurfaceForTesting() }
        #expect(!execSurface.resetRemoteOutput(columns: 80, rows: 24, replay: Data()))

        let manualSurface = makeSurface(ioMode: .manualMirror)
        defer {
            manualSurface.closeHeadlessStartupWindowIfNeeded()
            manualSurface.releaseSurfaceForTesting()
        }
        let oversized = Data(count: manualSurface.maxPendingRemoteOutputBytes + 1)
        #expect(!manualSurface.resetRemoteOutput(columns: 80, rows: 24, replay: oversized))
        #expect(manualSurface.pendingRemoteGrid == nil)
        #expect(manualSurface.pendingRemoteOutput.isEmpty)
    }

    @Test func liveResetFreesOnlyTheRuntimeAndKeepsTheModelIdentity() {
        let surface = makeSurface(ioMode: .manualMirror)
        let runtime = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        surface.installRuntimeSurfaceForTesting(runtime)
        let freed = RemoteResetFreedSurfaceBox()
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { freed.store($0) }
        defer {
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
            runtime.deallocate()
            surface.closeHeadlessStartupWindowIfNeeded()
            surface.releaseSurfaceForTesting()
        }

        let id = surface.id
        #expect(surface.resetRemoteOutput(
            columns: 100,
            rows: 30,
            replay: Data("restored".utf8)
        ))

        #expect(freed.matches(runtime))
        #expect(surface.id == id)
        #expect(!surface.hasLiveSurface)
        #expect(surface.pendingRemoteGrid?.columns == 100)
        #expect(surface.pendingRemoteGrid?.rows == 30)
        #expect(surface.pendingRemoteOutput == Data("restored".utf8))
        #expect(surface.debugBackgroundSurfaceStartQueuedForTesting())
    }

    @Test func failedBackgroundResetStartPublishesACompletionSignal() async {
        let surface = makeSurface(
            ioMode: .manualMirror,
            attachesThroughSurfaceModel: true
        )
        defer {
            surface.closeHeadlessStartupWindowIfNeeded()
            surface.releaseSurfaceForTesting()
        }

        let failureReason = RemoteResetFailureReasonBox()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("cmux.terminalSurfaceRuntimeCreationFailed"),
            object: surface,
            queue: .main
        ) { notification in
            failureReason.store(notification.userInfo?["reason"] as? String)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(surface.resetRemoteOutput(
            columns: 80,
            rows: 24,
            replay: Data("snapshot".utf8)
        ))
        for _ in 0..<100 where failureReason.load() == nil {
            await Task.yield()
        }

        #expect(failureReason.load() == "appNotInitialized")
        #expect(!surface.hasLiveSurface)
    }

    private func makeSurface(
        ioMode: TerminalSurfaceIOMode,
        attachesThroughSurfaceModel: Bool = false
    ) -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: attachesThroughSurfaceModel
        )
        let manualInputHandler: (@Sendable (TerminalManualInput) -> Void)?
        if ioMode.usesManualIO {
            manualInputHandler = { _ in }
        } else {
            manualInputHandler = nil
        }
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            ioMode: ioMode,
            manualInputHandler: manualInputHandler,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installClaudeCommandShim: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}
