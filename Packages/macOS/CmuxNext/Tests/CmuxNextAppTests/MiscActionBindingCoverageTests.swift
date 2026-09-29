import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// Binding coverage for the browser, notification, agent, and cloud actions,
/// plus their typed "unavailable: <reason>" results.
@MainActor
struct MiscActionBindingCoverageTests {
    static let categories: Set<ActionCategory> = [.browser, .notifications, .agents, .cloud]

    @Test func everyActionInTheseDomainsIsBound() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        let unbound = registry.unboundActionIDs(in: Self.categories)
        #expect(unbound.isEmpty, "unbound: \(unbound.map(\.rawValue).sorted())")
    }

    @Test func everyCloudActionIsUnavailableWithTheCloudReason() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        let cloud = registry.descriptors.filter { $0.category == .cloud }.map(\.id)
        #expect(!cloud.isEmpty)
        #expect(cloud.allSatisfy { registry.unavailableReason(for: $0) == HandlerStrings.cloud })
    }

    @Test func unportedViewerReportsItsReasonOutOfContext() {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context = []
        #expect(ActionBindingCoverageTests.run(services, "diffViewerNextHunk") == .refused(HandlerStrings.diffViewer))
    }

    @Test func splitBrowserNeedsFrontendBrowserTabs() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(ActionBindingCoverageTests.run(services, "splitBrowserRight") == .refused("needs daemon capability frontend-browser-tabs-v1"))
        #expect(ActionBindingCoverageTests.run(services, "markAllNotificationsRead") == .refused("needs daemon capability notification-ack-v1"))
    }

    @Test func handlersRefuseWithoutATarget() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(ActionBindingCoverageTests.run(services, "jumpToUnread") == .refused(HandlerStrings.noUnread))
        services.registry.context = [.terminalFocused]
        #expect(ActionBindingCoverageTests.run(services, "palette.forkAgentConversationNewTab") == .refused(HandlerStrings.noTerminal))
    }

    @Test func forkCommandOnlyForClaudeWithPlainSessionIDs() {
        #expect(AgentHandlers.forkCommand(agent: "claude", session: "ab-12_c") == "claude --resume ab-12_c --fork-session")
        #expect(AgentHandlers.forkCommand(agent: "codex", session: "ab") == nil)
        #expect(AgentHandlers.forkCommand(agent: "claude", session: "a; rm -rf ~") == nil)
    }
}
