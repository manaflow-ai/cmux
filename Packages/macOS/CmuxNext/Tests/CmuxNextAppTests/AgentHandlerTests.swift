import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// Agent chat opens through the same active-workspace tab path as Cmd-T when
/// no pane is focused yet (for example, while a seeded workspace is settling).
@MainActor @Suite struct AgentHandlerTests {
    @Test func newAgentChatEnsuresSameKindTabWhenNoPaneIsFocused() {
        let services = ActionBindingCoverageTests.boundServices()
        var ensured = false
        AgentHandlers.bind(into: services.registry, context: AppActionContext(services: services))
        services.registry.bind("newTab.sameKind") { ensured = true }

        #expect(services.registry.perform("palette.newAgentChat", invocation: ActionInvocation(origin: .user)))
        #expect(ensured, "Cmd-I must use the Cmd-T tab path before opening an agent tab")
    }
}
