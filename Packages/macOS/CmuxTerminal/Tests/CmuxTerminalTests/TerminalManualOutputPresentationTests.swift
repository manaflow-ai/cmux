import Foundation
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

extension TerminalRendererTests {
@MainActor
@Suite
struct TerminalManualOutputPresentationTests {
    @Test func aNewReplayRequiresItsOwnFrameAcknowledgement() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface
        var receipts: [UInt64] = []
        surface.onManualOutputPresented = { receipts.append($0) }

        let first = surface.requestManualOutputPresentation()
        let latest = surface.requestManualOutputPresentation()
        #expect(latest > first)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(receipts.isEmpty)
        #expect(!surface.isRendererPresented)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(receipts == [latest])
        #expect(surface.isRendererPresented)
    }

    @Test func reconnectCannotAcceptAPreviousReplayReceipt() {
        var receipt = TerminalManualOutputPresentation(expectedRevision: 2)
        let rejectedOld = receipt.acknowledge(1)
        #expect(!rejectedOld)
        #expect(!receipt.isPresented)
        let acceptedCurrent = receipt.acknowledge(2)
        #expect(acceptedCurrent)
        #expect(receipt.isPresented)
        receipt = .init(expectedRevision: 3)
        let rejectedPreviousSession = receipt.acknowledge(2)
        #expect(!rejectedPreviousSession)
        #expect(!receipt.isPresented)
    }

    @Test func tokenRequestWaitsUntilRemoteOutputWasParsed() async {
        let runtime = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let lane = TerminalSurfaceRemoteOutputLane(surfaceID: UUID(), generation: 1)
        let admissions = AsyncStream<Bool>.makeStream()
        let registered = ghostty_surface_set_render_presented_callback(runtime, { _, _ in }, nil)
        #expect(registered)
        cmux_test_ghostty_process_output_blocking_begin(runtime)
        defer {
            cmux_test_ghostty_process_output_release()
            lane.drainSynchronouslyForTesting()
            cmux_test_ghostty_process_output_blocking_reset()
            ghostty_surface_free(runtime)
            runtime.deallocate()
            admissions.continuation.finish()
        }
        lane.enqueue(Data("replay".utf8), to: runtime)
        let started = await Task.detached {
            cmux_test_ghostty_process_output_wait_until_started()
        }.value
        #expect(started)
        #expect(lane.enqueuePresentationProbe(7, to: runtime) { accepted in
            admissions.continuation.yield(accepted)
        })
        // The parser is deliberately stopped. A presentation request ahead
        // of its output would have a pending token here.
        #expect(!cmux_test_ghostty_renderer_present(runtime))
        cmux_test_ghostty_process_output_release()
        var iterator = admissions.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(cmux_test_ghostty_renderer_present(runtime))
    }
}
}
