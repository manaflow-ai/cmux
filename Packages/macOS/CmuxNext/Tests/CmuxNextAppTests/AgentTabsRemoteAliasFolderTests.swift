import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// A new chat on another machine keeps the provisional id its page was made with. Once the tree
/// settles, its ordinary alias goes (``AgentTabStore/releaseGoneTabs(in:)``) and only the machine's
/// remote alias still names the store's id, so the page's folder list resolves through it (#36767).
@MainActor @Suite(.serialized)
struct AgentTabsRemoteAliasFolderTests {
    @Test func aNewRemoteChatListsItsFoldersAfterTheProvisionalAliasGoes() async throws {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = "install:remote-alias-folder-test"
        let tree = DaemonStore()
        let record = AgentSessionRef(host: "install:the-mini", hostName: "mini", session: "s-mini", harness: "claude")
        tabs.lookupScoped = { $0.machine == "mini" ? (record, tree) : nil }
        tabs.remoteHostScoped = { _ in MockAgentPaneHost() }
        let provisional = AgentTabKey(machine: "mini", key: "tab_provisional")
        let view = try #require(tabs.view(for: provisional.key, machine: provisional.machine))
        tabs.remoteFoldersScoped = { $0.key == "tab_real" ? ["/repo"] : [] }
        tabs.remoteMachineFoldersScoped = { _ in [] }
        tabs.remoteCreations[provisional] = AgentTabPending(key: provisional.key, surface: .init(rawValue: 1))
        tabs.rekey(provisional.key, to: "tab_real", machine: provisional.machine)
        tabs.aliases.removeValue(forKey: provisional) // the settled tree no longer lists the provisional id
        let folders = await view.model.onListRemoteProjects?(nil)
        #expect(folders == ["/repo"], "the remote chat's folder list asked under its dropped provisional id: \(String(describing: folders))")
    }
}
