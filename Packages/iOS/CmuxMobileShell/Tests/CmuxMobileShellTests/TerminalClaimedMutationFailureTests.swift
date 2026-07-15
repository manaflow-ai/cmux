import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal claimed mutation failure")
struct TerminalClaimedMutationFailureTests {
    @Test("claimed mutation failure resolves before replay rotation and releases later mutations")
    func claimedFailureDoesNotWedgeReplayRelease() async throws {
        let store = MobileShellComposite.preview()
        let surfaceID = "claimed-failure"
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let failedReceipt = store.enqueueTerminalScrollToBottomMutation(surfaceID: surfaceID)
        let failedChunk = try #require(await iterator.next())
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: failedChunk.streamToken,
            deliveryID: failedChunk.deliveryID
        ))
        var failedResult: Bool?
        let failedWaiter = Task { @MainActor in
            failedResult = await failedReceipt.value
        }

        store.terminalOutputDidReset(
            surfaceID: surfaceID,
            streamToken: failedChunk.streamToken
        )

        let resolvedBeforeRotationCallback = try await pollUntil(attempts: 5) {
            failedResult != nil
        }
        #expect(resolvedBeforeRotationCallback)
        if !resolvedBeforeRotationCallback {
            // Clean up the red implementation's retained claimed waiter.
            store.terminalOutputDidReset(
                surfaceID: surfaceID,
                streamToken: failedChunk.streamToken
            )
        }
        await failedWaiter.value
        #expect(failedResult == false)

        let snapReceipt = store.enqueueTerminalScrollToBottomMutation(surfaceID: surfaceID)
        let snap = try #require(await iterator.next())
        apply(snap, store: store, surfaceID: surfaceID)
        #expect(await snapReceipt.value)

        let barrierReceipt = store.enqueueTerminalMutationBarrier(surfaceID: surfaceID)
        let barrier = try #require(await iterator.next())
        apply(barrier, store: store, surfaceID: surfaceID)
        #expect(await barrierReceipt.value)
        #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    }

    private func apply(
        _ chunk: MobileTerminalOutputChunk,
        store: MobileShellComposite,
        surfaceID: String
    ) {
        #expect(store.terminalOutputWillProcess(
            surfaceID: surfaceID,
            streamToken: chunk.streamToken,
            deliveryID: chunk.deliveryID
        ))
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
    }
}
