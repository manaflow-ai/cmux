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

    /// With the tab, workspace, and misc binders merged, no catalog action
    /// is left without a handler anywhere in the registry.
    @Test func registryHasNoUnboundActions() {
        let unbound = ActionBindingCoverageTests.boundServices().registry.unboundActionIDs()
        #expect(unbound.isEmpty, "unbound: \(unbound.map(\.rawValue).sorted())")
    }

    /// Signed out (and, in the test host, without a bundled cmux-tui), every
    /// Cloud action except diagnostics reports a typed Cloud reason; none
    /// falls back to the generic "no Cloud client" placeholder.
    @Test func cloudActionsReportTypedReasonsWhenCloudCannotRun() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        let cloud = registry.descriptors.filter { $0.category == .cloud }.map(\.id)
        #expect(!cloud.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: cloud.map { ($0, registry.unavailableReason(for: $0)) })
        #expect(reasons["cloudDiagnostics"]! == nil)
        #expect(reasons.allSatisfy { $0.value != MiscHandlerStrings.cloud })
        let unported: [ActionID: String] = ["palette.mobileConnect": CloudStrings.mobilePairing]
        for (id, reason) in unported { #expect(reasons[id]! == reason) }
        for id: ActionID in ["newCloudMachine", "cloudKillMachine", "cloudPauseMachine", "cloudResumeMachine", "palette.cloud.deleteSnapshot", "palette.cloud.status", "palette.cloud.tools", "palette.cloud.handoff",
                             "palette.cloud.promoteTemplate", "cloudSSH", "cloudExec"] {
            #expect([CloudStrings.noClient, CloudStrings.signInFirst, CloudStrings.localBackend].contains(reasons[id]!))
        }
    }

    /// diff-host S4: the diff viewer opens as a pane tab, so both open
    /// actions are bound with no unavailable reason.
    @Test func diffViewerOpenActionsAreBound() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        for id: ActionID in ["openDiffViewer", "palette.openDirectoryDiffViewer"] {
            #expect(registry.isBound(id), "\(id)")
            #expect(registry.unavailableReason(for: id) == nil, "\(id)")
        }
    }

    /// The 11 navigation actions are page commands of the focused diff tab:
    /// out of a diff tab they are unavailable by context, not unported.
    @Test func diffViewerNavigationNeedsAFocusedDiffTab() {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context = []
        for id in ["diffViewerNextHunk", "diffViewerNextLine", "diffViewerSearch"] {
            #expect(services.registry.unavailableReason(for: ActionID(rawValue: id)) == nil, "\(id)")
            #expect(ActionBindingCoverageTests.run(services, id) == .unavailable, "\(id)")
        }
    }

    @Test func splitBrowserNeedsFrontendBrowserTabs() {
        let services = ActionBindingCoverageTests.boundServices()
        for id in ["splitBrowserRight", "markAllNotificationsRead"] {
            let outcome = ActionBindingCoverageTests.run(services, id)
            #expect(CapabilityRefusalTests.refusedByGate(outcome), "\(id): \(outcome)")
        }
    }

    @Test func cloudExecRequiresAndTrimsItsCommand() throws {
        let invocation = ActionInvocation(arguments: ["command": .string("  uname -a  ")])
        #expect(try CloudHandlers.commandArgument(invocation) == "uname -a")
        #expect(throws: ActionFailure.self) {
            try CloudHandlers.commandArgument(ActionInvocation(arguments: ["command": .string("  ")]))
        }
    }

    @Test func handlersRefuseWithoutATarget() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(ActionBindingCoverageTests.run(services, "jumpToUnread") == .refused(MiscHandlerStrings.noUnread))
        services.registry.context = [.terminalFocused]
        #expect(ActionBindingCoverageTests.run(services, "palette.forkAgentConversationNewTab") == .refused(MiscHandlerStrings.noTerminal))
    }

    @Test func forkCommandOnlyForClaudeWithPlainSessionIDs() {
        #expect(AgentHandlers.forkCommand(agent: "claude", session: "ab-12_c") == "claude --resume ab-12_c --fork-session")
        #expect(AgentHandlers.forkCommand(agent: "codex", session: "ab") == nil)
        #expect(AgentHandlers.forkCommand(agent: "claude", session: "a; rm -rf ~") == nil)
    }

    @Test func continueInIsAUserChooserBackedByTheSharedFrontendFlow() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "agentPane.continueIn" })
        #expect(descriptor.requires.contains(.agentPaneFocused))
        #expect(descriptor.targets == [.pane])
        #expect(descriptor.surfacePlan.cli == .exempt(.guiOnly))
        #expect(descriptor.surfacePlan.contextMenu == .exempt(.guiOnly))
        #expect(ActionBindingCoverageTests.boundServices().registry.isBound("agentPane.continueIn"))
    }
    @Test func checkpointReviewNeedsTheFocusedPagesCapability() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let id: ActionID = "agentPane.createCheckpoint"
        #expect(services.registry.isBound(id))
        #expect(!services.registry.isAvailable(id, in: [.agentPaneFocused]))
        #expect(!services.registry.isAvailable(id, in: [.checkpointCaptureAvailable]))
        #expect(services.registry.isAvailable(id, in: [.agentPaneFocused, .checkpointCaptureAvailable]))
    }
}
