import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_process_output_blocking_begin")
private func beginBlockingProcessOutput(_ surface: ghostty_surface_t)

@_silgen_name("cmux_test_ghostty_process_output_wait_until_started")
private func waitUntilProcessOutputStarted() -> Bool

@_silgen_name("cmux_test_ghostty_process_output_called_on_main_thread")
private func processOutputWasCalledOnMainThread() -> Bool

@_silgen_name("cmux_test_ghostty_process_output_release")
private func releaseBlockingProcessOutput()

@_silgen_name("cmux_test_ghostty_process_output_blocking_reset")
private func resetBlockingProcessOutput()

@MainActor
private final class RemoteOutputFixture {
    let surface: TerminalSurface

    init(surface: TerminalSurface) {
        self.surface = surface
    }

    func processOutput() {
        surface.processRemoteOutput(Data("remote output".utf8))
    }

    func releaseSurface() {
        surface.releaseSurfaceForTesting()
    }
}

@Suite(.serialized)
struct TerminalSurfaceRemoteOutputTests {
    @Test
    func remoteOutputDoesNotBlockTheMainActorOnNativeParser() async {
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let runtimeSurfaceBits = UInt(bitPattern: runtimeSurface)
        let fixture = await MainActor.run {
            RemoteOutputFixture(surface: makeSurface(runtimeSurfaceBits: runtimeSurfaceBits))
        }
        defer {
            releaseBlockingProcessOutput()
            resetBlockingProcessOutput()
        }

        beginBlockingProcessOutput(
            UnsafeMutableRawPointer(bitPattern: runtimeSurfaceBits)!
        )
        let outputTask = Task { @MainActor in
            fixture.processOutput()
        }

        let started = await Task.detached {
            waitUntilProcessOutputStarted()
        }.value
        #expect(started)

        let mainActorMarker = AsyncStream<Void>.makeStream()
        let mainActorMarkerTask = Task { @MainActor in
            mainActorMarker.continuation.yield()
            mainActorMarker.continuation.finish()
        }
        let mainActorStayedResponsive = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = mainActorMarker.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(5))
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            // Finish the stream before the group scope waits for its children;
            // otherwise a blocked main actor leaves the marker waiter alive
            // after the deadline and the test cannot release the stub.
            mainActorMarker.continuation.finish()
            group.cancelAll()
            return result
        }
        #expect(mainActorStayedResponsive)

        #expect(!processOutputWasCalledOnMainThread())
        releaseBlockingProcessOutput()
        _ = await outputTask.value
        _ = await mainActorMarkerTask.value
        await MainActor.run {
            fixture.releaseSurface()
        }
        runtimeSurface.deallocate()
    }

    @MainActor
    private func makeSurface(
        runtimeSurfaceBits: UInt
    ) -> TerminalSurface {
        let runtimeSurface = UnsafeMutableRawPointer(bitPattern: runtimeSurfaceBits)!
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let registry = FakeSurfaceRegistry()
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
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
                    agentCommandShimTemporaryDirectory: URL(
                        fileURLWithPath: "/tmp/cmux-terminal-tests",
                        isDirectory: true
                    ),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        return surface
    }
}
