import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Capture of build 8603d77b (the toolbar-diffviewer flow): an agent chat opened beside Home's
/// Chief, with no title yet, was titled "Home" in its tab, and Home's Your agents listed it as
/// "Home". A chat with no title reads as the name of the workspace it is in (a Chief names each
/// subagent's workspace after its task, 169b3feea07), but Home's name is the Home workspace's, not
/// a task: the chat there reads "Agent" until it has a title of its own. Any other workspace's
/// name still stands in.
@MainActor @Suite(.serialized) struct HomeChatTabTitleTests {
    static let home = WorkspaceHandle(rawValue: 1), fleet = WorkspaceHandle(rawValue: 2)

    /// The Home workspace and "Fleet uploader", each holding one untitled chat tab on a session the
    /// app's turn states do not know (so no chat title).
    private static func services() throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        func workspace(_ id: WorkspaceHandle, name: String, kind: String?) -> WorkspaceSnapshot {
            var tab = TabSnapshot(surface: SurfaceID(rawValue: id.rawValue), kind: .conversation)
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:home-chat-title", session: "s\(id.rawValue)",
                                                                                harness: "claude"))
            let pane = PaneSnapshot(id: PaneID(rawValue: id.rawValue), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id.rawValue), layout: .leaf(pane.id), panes: [pane])
            var snapshot = WorkspaceSnapshot(id: id, key: nil, name: name, screens: [screen])
            snapshot.kind = kind
            return snapshot
        }
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [
            workspace(home, name: "Home", kind: SidebarMapping.homeKind),
            workspace(fleet, name: "Fleet uploader", kind: nil),
        ]))
        return services
    }

    /// The title the strip of workspace `handle`'s one pane gives its chat tab.
    private static func stripTitle(in handle: WorkspaceHandle, _ services: AppServices) throws -> String? {
        let model = try #require(services.daemon.store.workspaces.first { $0.handle == handle }?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        defer { pane.teardown() }
        pane.syncStripFromStore()
        return pane.stripModel.tabs.first?.title
    }

    @Test func anUntitledChatInHomeIsNotTitledHome() throws {
        let services = try Self.services()
        #expect(try Self.stripTitle(in: Self.home, services) == AgentPaneModel.tabTitle,
                "a chat in Home took the Home workspace's name as its title")
        #expect(try Self.stripTitle(in: Self.fleet, services) == "Fleet uploader",
                "a chat in another workspace still reads as that workspace's task")
    }

    @Test func homesYourAgentsNeverListsAChatAsHome() throws {
        let services = try Self.services()
        let titles = HomeAgentGlances(services: services).current.map(\.title)
        #expect(titles.sorted() == [AgentPaneModel.tabTitle, "Fleet uploader"].sorted(), "Your agents listed \(titles)")
    }
}
