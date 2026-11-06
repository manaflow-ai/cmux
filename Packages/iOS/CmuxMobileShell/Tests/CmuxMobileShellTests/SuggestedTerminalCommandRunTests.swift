import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct SuggestedTerminalCommandRunTests {
    @Test func sendsTheWholeEditedCommandThroughTheValidatedAgentRoute() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        await router.setCommandSession(.init(
            id: "claude", agentKind: .claude, workspaceID: RoutingHostRouter.workspaceID,
            terminalID: RoutingHostRouter.terminalA
        ))
        let original = "! bash ~/scripts/original.sh"
        let edited = "! bash <<'SCRIPT'\nprintf '%s\\n' 'hello world'\nSCRIPT"
        let suggestion = TerminalCommandSuggestion(sessionID: "claude", text: original)
        let sent = await store.runSuggestedTerminalCommand(
            suggestion, editedText: edited,
            workspaceID: .init(rawValue: RoutingHostRouter.workspaceID),
            terminalID: .init(rawValue: RoutingHostRouter.terminalA)
        )
        #expect(sent)
        let sends = await router.commandSends
        #expect(sends.count == 1)
        #expect(sends.first?.text == edited)
        #expect(sends.first?.sessionID == "claude")
        #expect(await router.pastes.isEmpty)
    }

    @Test func canonicalSendRejectsAnExitedAgentDespiteACachedDescriptor() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        await router.setCommandSession(.init(
            id: "claude", agentKind: .claude, workspaceID: RoutingHostRouter.workspaceID,
            terminalID: RoutingHostRouter.terminalA
        ))
        await router.setRejectCommandSend(true)
        let suggestion = TerminalCommandSuggestion(sessionID: "claude", text: "! pwd")
        #expect(await !store.runSuggestedTerminalCommand(
            suggestion, editedText: suggestion.text,
            workspaceID: .init(rawValue: RoutingHostRouter.workspaceID),
            terminalID: .init(rawValue: RoutingHostRouter.terminalA)
        ))
        #expect(await router.pastes.isEmpty)
        #expect(await router.commandSends.isEmpty)
    }

    @Test func doesNotPasteIntoAChangedSessionBinding() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        await router.setCommandSession(.init(
            id: "claude", agentKind: .claude, workspaceID: RoutingHostRouter.workspaceID,
            terminalID: RoutingHostRouter.terminalB
        ))
        let suggestion = TerminalCommandSuggestion(sessionID: "claude", text: "! bash ~/scripts/run.sh")
        #expect(await !store.runSuggestedTerminalCommand(
            suggestion, editedText: suggestion.text,
            workspaceID: .init(rawValue: RoutingHostRouter.workspaceID),
            terminalID: .init(rawValue: RoutingHostRouter.terminalA)
        ))
        #expect(await router.pastes.isEmpty)
    }

    @Test func doesNotPasteWhenOriginalSessionCannotBeVerified() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let suggestion = TerminalCommandSuggestion(sessionID: "missing", text: "! pwd")
        #expect(await !store.runSuggestedTerminalCommand(
            suggestion, editedText: suggestion.text,
            workspaceID: .init(rawValue: RoutingHostRouter.workspaceID),
            terminalID: .init(rawValue: RoutingHostRouter.terminalA)
        ))
        #expect(await router.pastes.isEmpty)
    }
}
