import Foundation
import GhosttyKit
import CmuxTerminalGhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

extension TerminalSurfaceTeardownCallbackLifetimeTests {
    @Test(arguments: [false, true])
    func teardownDrainsRemoteOutputBeforeNativeRetirement(deinitOnly: Bool) async throws {
        let recorder = TeardownOrderRecorder()
        var surface: TerminalSurface? = makeSurface()
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { runtimeSurface.deallocate() }
        defer { cmux_test_ghostty_surface_request_process_termination_reset(runtimeSurface) }
        surface?.installRuntimeSurfaceForTesting(runtimeSurface)
        cmux_test_ghostty_surface_request_process_termination_reset(runtimeSurface)
        cmux_test_ghostty_process_output_blocking_begin(runtimeSurface)
        defer {
            cmux_test_ghostty_process_output_release()
            cmux_test_ghostty_process_output_blocking_reset()
        }

        surface?.remoteOutputLane.enqueue(Data("pending output".utf8), to: runtimeSurface)
        let started = await Task.detached {
            cmux_test_ghostty_process_output_wait_until_started()
        }.value
        try #require(started, "remote output did not reach the native parser")
        do {
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { surface in
                #expect(
                    cmux_test_ghostty_surface_request_process_termination_call_count(surface) == 1,
                    "native routing must be retired after output drains and before free"
                )
                recorder.record(.nativeFree)
            }
            defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

            if deinitOnly {
                surface = nil
            } else {
                surface?.teardownSurface()
            }
        }

        #expect(
            cmux_test_ghostty_surface_request_process_termination_call_count(runtimeSurface) == 0,
            "retirement must wait for admitted output and refresh calls to finish"
        )
        cmux_test_ghostty_process_output_release()
        #expect(await recorder.waitForEventCount(1), "timed out waiting for native free")
    }

    @Test func agentHibernationSuspendKeepsTeeLeaseUntilNativeFree() async {
        let recorder = TeardownOrderRecorder()
        let registry = TerminalSurfaceRegistry()
        let surface = makeSurface(registry: registry)
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
        surface.installRuntimeSurfaceForTesting(runtimeSurface)
        defer { runtimeSurface.deallocate() }
        defer { cmux_test_ghostty_surface_request_process_termination_reset(runtimeSurface) }
        surface.mobileByteTeeLease = RecordingTerminalByteTeeLease(recorder: recorder)
        do {
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { surface in
                #expect(
                    cmux_test_ghostty_surface_request_process_termination_call_count(surface) == 1,
                    "hibernation must retire native app routing before its isolated free"
                )
                recorder.record(.nativeFree)
            }
            defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }
            cmux_test_ghostty_surface_request_process_termination_reset(runtimeSurface)

            surface.suspendRuntimeSurfaceForAgentHibernation(reason: "test.hibernate")
        }

        #expect(
            !recorder.events.contains(.teeLeaseRelease),
            "tee lease was released before the native free; the IO reader thread can still fire the tee callback"
        )

        let completed = await recorder.waitForEventCount(2)
        #expect(completed, "timed out waiting for native free and tee-lease release")
        #expect(
            cmux_test_ghostty_surface_request_process_termination_call_count(runtimeSurface) == 1,
            "hibernation must retire native app routing before its isolated free"
        )
        #expect(recorder.events == [.nativeFree, .teeLeaseRelease])
    }

}
