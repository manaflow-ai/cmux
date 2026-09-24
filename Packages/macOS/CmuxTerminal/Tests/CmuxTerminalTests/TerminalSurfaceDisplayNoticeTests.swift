import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_io_recording_begin")
private func beginIORecording(_ surface: ghostty_surface_t)

@_silgen_name("cmux_test_ghostty_io_recording_reset")
private func resetIORecording()

@_silgen_name("cmux_test_ghostty_recorded_process_output")
private func recordedProcessOutput(
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: UInt
) -> UInt

@_silgen_name("cmux_test_ghostty_recorded_input_call_count")
private func recordedInputCallCount() -> UInt32

private func recordedProcessOutputString() -> String {
    let length = Int(recordedProcessOutput(nil, 0))
    guard length > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: length)
    _ = buffer.withUnsafeMutableBufferPointer {
        recordedProcessOutput($0.baseAddress, UInt(length))
    }
    return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Restore notices (#12158 and the live-owner takeover notice) are cmux's own
/// words. They must render as terminal output and never reach the shell as
/// typed input, or the pane echoes a `/usr/bin/printf` command line before
/// the prompt is ready.
@MainActor
@Suite(.serialized)
struct TerminalSurfaceDisplayNoticeTests {
    @Test("A deferred-restore notice is display output and nothing is typed into the shell")
    func deferredRestoreNoticeIsDisplayOutputNotShellInput() {
        let fixture = makeFixture(configuredInitialInput: "resume codex session\n")
        defer { fixture.tearDown() }

        #expect(fixture.surface.admitStartupRestoreRuntime(
            displayNotice: "cmux did not resume.\nRun 'cmux restore --surface'."
        ))

        // The shell starts with no typed input: neither the notice nor the
        // deferred agent-resume payload the surface was configured with.
        #expect(fixture.surface.runtimeInitialInputForNextSpawn(
            configuredDefault: "ghostty-config-initial-input"
        ) == nil)
        // Admission still starts the runtime.
        #expect(fixture.scheduler.scheduledSurfaceIds == [fixture.surface.id])

        fixture.installRuntime()
        fixture.surface.flushPendingDisplayNotices(to: fixture.runtime)

        #expect(recordedProcessOutputString() ==
            "\u{1B}[2mcmux did not resume.\r\nRun 'cmux restore --surface'.\u{1B}[22m\r\n")
        #expect(recordedInputCallCount() == 0)
    }

    @Test("A notice written to a live terminal starts on its own line")
    func liveNoticeIsDisplayOutputOnItsOwnLine() {
        let fixture = makeFixture(configuredInitialInput: nil)
        defer { fixture.tearDown() }
        fixture.installRuntime()

        fixture.surface.writeDisplayNotice("already running\r\nin process 42")

        #expect(recordedProcessOutputString() ==
            "\r\n\u{1B}[2malready running\r\nin process 42\u{1B}[22m\r\n")
        #expect(recordedInputCallCount() == 0)
        #expect(fixture.surface.runtimeInitialInputForNextSpawn(configuredDefault: nil) == nil)
    }

    @Test("Control characters in a notice cannot drive the terminal")
    func noticeStripsControlCharacters() {
        let fixture = makeFixture(configuredInitialInput: nil)
        defer { fixture.tearDown() }

        fixture.surface.writeDisplayNotice("a\u{1B}]52;c;ZXZpbA==\u{07}b\u{9B}2Jc")
        fixture.installRuntime()
        fixture.surface.flushPendingDisplayNotices(to: fixture.runtime)

        #expect(recordedProcessOutputString() ==
            "\u{1B}[2ma]52;c;ZXZpbA==b2Jc\u{1B}[22m\r\n")
    }

    private struct Fixture {
        let surface: TerminalSurface
        let registry: FakeSurfaceRegistry
        let scheduler: RecordingRestoreSpawnScheduler
        let runtimePointer: UnsafeMutableRawPointer

        var runtime: ghostty_surface_t { runtimePointer }

        @MainActor
        func installRuntime() {
            beginIORecording(runtime)
            registry.registerRuntimeSurface(runtime, ownerId: surface.id)
            surface.installRuntimeSurfaceForTesting(runtime)
        }

        @MainActor
        func tearDown() {
            surface.releaseSurfaceForTesting()
            surface.closeHeadlessStartupWindowIfNeeded()
            resetIORecording()
            runtimePointer.deallocate()
        }
    }

    private func makeFixture(configuredInitialInput: String?) -> Fixture {
        resetIORecording()
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: configuredInitialInput,
            runtimeSpawnPolicy: .pacedSessionRestore
                .requiringDeferredAgentResumeAdmission(),
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
                restoreSpawnScheduler: scheduler,
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
        surface.agentCommandShimInstallCompleted = true
        return Fixture(
            surface: surface,
            registry: registry,
            scheduler: scheduler,
            runtimePointer: UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        )
    }
}
