import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// #22292: restore two workspaces through the app's service wiring without ever showing a pane.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentChatsStartupTests {
    private static let thisMac = "install:startup-resume-test"

    private static func tree(_ sessions: [String]) -> DaemonTree {
        let workspaces = sessions.enumerated().map { index, session in
            let id = index + 1
            var tab = TabSnapshot(surface: SurfaceID(rawValue: UInt64(id)), kind: .conversation,
                                  title: "Chat", url: "about:blank")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: thisMac, session: session))
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(id)), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(id)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(id)), key: nil, name: "Workspace \(id)", screens: [screen])
        }
        return DaemonTree(workspaces: workspaces)
    }

    @Test func serviceStartupResumesChatsInUnopenedWorkspaces() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]),
                                   agentPaneEnvironment: ["CMUX_NEXT_AGENT_PANE_MOCK": "1"])
        let store = services.daemon.store
        store.applyProvisional(snapshot: Self.tree(["stale-cached-chat"]))
        let tabs = services.agentTabs
        let host = AgentChatsStartupRecordingHost()
        tabs.localHost = Self.thisMac
        tabs.localSessionHost = host
        let resumed = host.resumed

        store.apply(.connected(DaemonIdentity(generation: DaemonGeneration(rawValue: "startup-test")), generationChanged: false))
        store.apply(snapshot: Self.tree(["first-workspace-chat", "unopened-workspace-chat"]))
        // AsyncStream cancellation ends the wait on the red revision. A missing launch resume
        // is a behavioral failure, not a missing-API compile error or a zero-test pass.
        let received = try await withAgentPaneDeadline(.seconds(5), label: "restored workspace agents start") {
            var sessions: [String] = []
            for await session in resumed {
                sessions.append(session)
                if sessions.count == 2 { break }
            }
            return sessions
        }
        #expect(Set(received) == ["first-workspace-chat", "unopened-workspace-chat"])
        #expect(await host.calls.count == 2)
        #expect(tabs.views.isEmpty, "restoring agents must not construct hidden chat pages")
    }
}
