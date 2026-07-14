import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal bottom prefetch")
struct TerminalBottomPrefetchTests {
    @Test("input bottom snap restores older-heavy replay prefetch")
    func inputBottomSnapRestoresPrefetchDirection() async throws {
        let session = TerminalScrollSession(
            surfaceID: "terminal",
            interactionEpoch: 1,
            enqueueLocal: { _ in resolvedReceipt() },
            enqueueBarrier: { resolvedReceipt() },
            enqueueScrollToBottom: { resolvedReceipt() },
            cancelLocal: {},
            sendRemote: { request in
                TerminalScrollResponse(
                    accepted: true,
                    interactionEpoch: request.interactionEpoch,
                    clientRevision: request.clientRevision,
                    renderRevision: 1,
                    renderGrid: nil
                )
            },
            prepareIntent: {},
            deliverAuthoritative: { _, _, _, _ in false },
            completeGridlessAuthoritative: { _ in true },
            reconciliationDidComplete: {},
            requestReplay: { _ in },
            advanceEpoch: { 2 }
        )

        session.submit(lines: -8, col: 1, row: 1)
        #expect(session.replayPrefetchWindow == TerminalScrollPrefetchWindow(
            rowsBeforeViewport: 120,
            rowsAfterViewport: 600
        ))

        _ = session.submitInput(.fence)

        try #require(await pollUntil {
            session.replayPrefetchWindow == TerminalScrollPrefetchWindow(
                rowsBeforeViewport: 600,
                rowsAfterViewport: 120
            )
        })
        #expect(session.replayPrefetchWindow == TerminalScrollPrefetchWindow(
            rowsBeforeViewport: 600,
            rowsAfterViewport: 120
        ))
    }

    private func resolvedReceipt() -> TerminalSurfaceMutationReceipt {
        let receipt = TerminalSurfaceMutationReceipt()
        receipt.resolve(true)
        return receipt
    }
}
