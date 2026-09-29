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

@MainActor
private final class ReplayCompletionBox {
    var called = false
}

@Suite(.serialized)
struct TerminalSurfaceRemoteOutputTests {
    @Test
    func bufferedReplayOverflowReportsDiscardedInsteadOfApplying() async {
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let runtimeSurfaceBits = UInt(bitPattern: runtimeSurface)
        let fixture = await MainActor.run {
            RemoteOutputFixture(surface: makeSurface(runtimeSurfaceBits: runtimeSurfaceBits))
        }
        let completion = await MainActor.run { ReplayCompletionBox() }
        let discard = await MainActor.run { ReplayCompletionBox() }
        defer {
            runtimeSurface.deallocate()
        }

        await MainActor.run {
            fixture.releaseSurface()
            fixture.surface.processRemoteReplay(Data("replay".utf8), onApplied: {
                completion.called = true
            }, onDiscarded: {
                discard.called = true
            })
            fixture.surface.processRemoteOutput(
                Data(repeating: 0x41, count: fixture.surface.maxPendingRemoteOutputBytes)
            )
            #expect(discard.called)
            #expect(!completion.called)

            let oversized = Data(repeating: 0x42, count: fixture.surface.maxPendingRemoteOutputBytes + 1)
            fixture.surface.processRemoteReplay(oversized, onApplied: {
                completion.called = true
            }, onDiscarded: {
                discard.called = true
            })
            #expect(discard.called)
            #expect(!completion.called)
        }
    }

    @Test
    func bufferedReplayCompletionWaitsForRuntimeFlush() async {
        let initialRuntime = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let replacementRuntime = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let initialBits = UInt(bitPattern: initialRuntime)
        let replacementBits = UInt(bitPattern: replacementRuntime)
        let fixture = await MainActor.run {
            RemoteOutputFixture(surface: makeSurface(runtimeSurfaceBits: initialBits))
        }
        let completion = await MainActor.run { ReplayCompletionBox() }
        defer {
            initialRuntime.deallocate()
            replacementRuntime.deallocate()
        }

        await MainActor.run {
            fixture.releaseSurface()
            fixture.surface.processRemoteReplay(Data("buffered replay".utf8)) {
                completion.called = true
            }
            #expect(!completion.called)
            let replacement = UnsafeMutableRawPointer(bitPattern: replacementBits)!
            fixture.surface.installRuntimeSurfaceForTesting(replacement)
            fixture.surface.flushPendingRemoteOutput(to: replacement)
        }

        for _ in 0 ..< 100 {
            if await MainActor.run(body: { completion.called }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await MainActor.run(body: { completion.called }))
        await MainActor.run { fixture.releaseSurface() }
    }

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

    @Test
    @MainActor
    func automaticClipboardWritesRequireLocalExecOwnership() {
        let local = makeSurface(runtimeSurfaceBits: UInt(bitPattern: UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)))
        defer { local.surface!.deallocate() }
        #expect(local.allowsAutomaticClipboardWrite)

        let remote = makeSurface(
            runtimeSurfaceBits: UInt(bitPattern: UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)),
            isRemoteTerminal: true
        )
        defer { remote.surface!.deallocate() }
        #expect(!remote.allowsAutomaticClipboardWrite)
    }

    @MainActor
    private func makeSurface(
        runtimeSurfaceBits: UInt,
        isRemoteTerminal: Bool = false
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
            isRemoteTerminal: isRemoteTerminal,
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
                    agentCommandShimRootDirectory: URL(
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
