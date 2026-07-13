import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal input connection reset")
struct TerminalInputConnectionResetTests {
    @Test("old client acknowledgement completes a dispatched input exactly once")
    func oldClientAcknowledgementSurvivesReset() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstPasteImage(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let send = Task { @MainActor in
            await store.submitTerminalInputIntent(
                .image(
                    Data(repeating: 0xA5, count: 1_000_000),
                    format: "png",
                    workspaceID: RoutingHostRouter.workspaceID
                ),
                surfaceID: RoutingHostRouter.terminalA
            )
        }

        await router.awaitFirstPasteImageReached()
        let session = try #require(store.terminalScrollSessionsBySurfaceID[RoutingHostRouter.terminalA])
        guard case .inputSend = session.phase else {
            Issue.record("Expected input to be dispatched before reset")
            return
        }

        store.bumpConnectionGenerationForTesting()
        store.replaceRemoteClient(with: nil)

        guard case .inputSend = session.phase else {
            Issue.record("Connection reset must preserve the dispatched input")
            return
        }
        await router.releaseFirstPasteImage()

        #expect(await send.value)
        #expect(await router.recordedPasteImages().count == 1)
    }

    @Test("old client failure fails a dispatched input without retry")
    func oldClientFailureSurvivesReset() async throws {
        let router = RoutingHostRouter()
        await router.setHoldFirstPasteImage(true)
        await router.setRejectPasteImage(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let send = Task { @MainActor in
            await store.submitTerminalInputIntent(
                .image(
                    Data(repeating: 0x5A, count: 1_000_000),
                    format: "png",
                    workspaceID: RoutingHostRouter.workspaceID
                ),
                surfaceID: RoutingHostRouter.terminalA
            )
        }

        await router.awaitFirstPasteImageReached()
        let session = try #require(store.terminalScrollSessionsBySurfaceID[RoutingHostRouter.terminalA])
        guard case .inputSend = session.phase else {
            Issue.record("Expected input to be dispatched before reset")
            return
        }

        store.bumpConnectionGenerationForTesting()
        store.replaceRemoteClient(with: nil)

        guard case .inputSend = session.phase else {
            Issue.record("Connection reset must preserve the dispatched input")
            return
        }
        await router.releaseFirstPasteImage()

        #expect(await send.value == false)
        #expect(await router.recordedPasteImages().count == 1)
    }
}
