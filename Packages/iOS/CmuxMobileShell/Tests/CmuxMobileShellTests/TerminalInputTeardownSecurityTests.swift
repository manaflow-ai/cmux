import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal input teardown security")
struct TerminalInputTeardownSecurityTests {
    @Test("security teardown cancels text paste and image without post-teardown success")
    func securityTeardownCancelsDispatchedInput() async throws {
        for teardown in InputTeardown.allCases {
            for input in HeldInput.allCases {
                let router = RoutingHostRouter()
                await router.holdNextTerminalInput(method: input.method)
                let store = try await makeRoutingConnectedStore(router: router)
                let send = Task { @MainActor in
                    await store.submitTerminalInputIntent(
                        input.intent,
                        surfaceID: RoutingHostRouter.terminalA
                    )
                }
                await router.awaitHeldTerminalInputReached()

                teardown.apply(to: store)

                let disconnectedWhileRequestHeld = try await pollUntil {
                    await router.recordedTransportCloseCount() == 1
                }
                #expect(
                    disconnectedWhileRequestHeld,
                    "\(teardown) must close a client holding \(input.method)"
                )

                await router.releaseHeldTerminalInput()
                #expect(await send.value == false)
                #expect(await router.recordedTransportCloseCount() == 1)
                let session = try #require(
                    store.terminalScrollSessionsBySurfaceID[RoutingHostRouter.terminalA]
                )
                guard case .idle = session.phase else {
                    Issue.record("\(teardown) left \(input.method) active after disconnect")
                    continue
                }
            }
        }
    }

    @Test("controlled nonnil replacement preserves dispatched text paste and image")
    func controlledReplacementPreservesDispatchedInput() async throws {
        for input in HeldInput.allCases {
            let oldRouter = RoutingHostRouter()
            await oldRouter.holdNextTerminalInput(method: input.method)
            let store = try await makeRoutingConnectedStore(router: oldRouter)
            let send = Task { @MainActor in
                await store.submitTerminalInputIntent(
                    input.intent,
                    surfaceID: RoutingHostRouter.terminalA
                )
            }
            await oldRouter.awaitHeldTerminalInputReached()

            store.bumpConnectionGenerationForTesting()
            try installFreshRemoteClient(on: store, router: RoutingHostRouter())
            await Task.yield()

            #expect(await oldRouter.recordedTransportCloseCount() == 0)
            let session = try #require(
                store.terminalScrollSessionsBySurfaceID[RoutingHostRouter.terminalA]
            )
            guard case .inputSend = session.phase else {
                Issue.record("Nonnil replacement cancelled \(input.method)")
                await oldRouter.releaseHeldTerminalInput()
                continue
            }

            await oldRouter.releaseHeldTerminalInput()
            #expect(await send.value)
            #expect(try await pollUntil {
                await oldRouter.recordedTransportCloseCount() == 1
            })
        }
    }
}

private enum InputTeardown: CaseIterable, CustomStringConvertible {
    case signOut
    case authorizationFailure
    case explicitDisconnect

    var description: String {
        switch self {
        case .signOut: "sign out"
        case .authorizationFailure: "authorization failure"
        case .explicitDisconnect: "explicit disconnect"
        }
    }

    @MainActor
    func apply(to store: MobileShellComposite) {
        switch self {
        case .signOut:
            store.signOut()
        case .authorizationFailure:
            #expect(store.disconnectForAuthorizationFailureIfNeeded(
                MobileShellConnectionError.authorizationFailed("expired")
            ))
        case .explicitDisconnect:
            store.disconnectLiveConnection()
        }
    }
}

private enum HeldInput: CaseIterable {
    case text
    case paste
    case image

    var method: String {
        switch self {
        case .text: "terminal.input"
        case .paste: "terminal.paste"
        case .image: "terminal.paste_image"
        }
    }

    var intent: TerminalInputIntent {
        switch self {
        case .text:
            .text("secret", workspaceID: RoutingHostRouter.workspaceID)
        case .paste:
            .paste("secret", submitKey: "", workspaceID: RoutingHostRouter.workspaceID)
        case .image:
            .image(Data([1, 2, 3]), format: "png", workspaceID: RoutingHostRouter.workspaceID)
        }
    }
}
