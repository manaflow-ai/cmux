import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// A Cloud chat started from this Mac's tab shows in that tab, in place (cmux#47677): its Cloud workspace is
/// held out of every window from before it is made, the Mac tab draws its page, and each side's close ends the pairing.
@MainActor
struct CloudFrontedChatsTests {
    private let mac = AgentTabKey(machine: "local", key: "mac-tab")
    private let front = CloudFrontedChats.Front(machine: "vm-1", key: "cloud-tab", workspace: "cloud-ws")

    @Test func aStartHoldsItsWorkspaceBeforeItListsAndTheMacTabShowsTheChat() {
        let fronts = CloudFrontedChats()
        #expect(fronts.isEmpty)
        fronts.hold("cloud-ws")
        #expect(fronts.workspaceIDs == ["cloud-ws"])
        #expect(fronts.front(of: mac) == nil)
        fronts.front(mac, with: front)
        #expect(fronts.front(of: mac) == front)
        #expect(fronts.workspaceIDs == ["cloud-ws"])
        #expect(fronts.mac(showing: front.tab) == mac)
        #expect(fronts.mac(showingWorkspace: "cloud-ws") == mac)
        #expect(fronts.front(of: AgentTabKey(machine: "vm-1", key: "mac-tab")) == nil)
    }

    @Test func closingTheMacTabEndsTheCloudChat() {
        let fronts = CloudFrontedChats()
        var closed: [CloudFrontedChats.Front] = [], reshown: [AgentTabKey] = []
        fronts.closeCloud = { closed.append($0) }
        fronts.reshow = { reshown.append($0) }
        fronts.front(mac, with: front)
        fronts.gone(mac)
        #expect(closed == [front])
        #expect(reshown.isEmpty)
        #expect(fronts.isEmpty)
        #expect(fronts.workspaceIDs.isEmpty)
    }

    @Test func theCloudTabGoingGivesTheMacTabItsOwnPageBack() {
        let fronts = CloudFrontedChats()
        var closed: [CloudFrontedChats.Front] = [], reshown: [AgentTabKey] = []
        fronts.closeCloud = { closed.append($0) }
        fronts.reshow = { reshown.append($0) }
        fronts.front(mac, with: front)
        fronts.gone(AgentTabKey(machine: "vm-1", key: "other"))
        #expect(fronts.front(of: mac) == front)
        fronts.gone(front.tab)
        #expect(reshown == [mac])
        #expect(closed.isEmpty)
        #expect(fronts.front(of: mac) == nil)
    }

    @Test func frontsLastAcrossARelaunch() throws {
        let suite = "CloudFrontedChatsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fronts = CloudFrontedChats()
        fronts.defaults = { defaults }
        fronts.front(mac, with: front)
        let relaunched = CloudFrontedChats()
        relaunched.defaults = { defaults }
        relaunched.restore()
        #expect(relaunched.front(of: mac) == front)
        #expect(relaunched.workspaceIDs == ["cloud-ws"])
        relaunched.gone(mac)
        #expect(defaults.data(forKey: CloudFrontedChats.defaultsKey) == nil)
    }

    @Test func theMacTabReadsAsTheChatItShowsNeverNewTab() throws {
        let daemon = DaemonService()
        let ref = AgentSessionRef(host: "install:this-mac", session: nil, harness: "claude")
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        page.conversation = ConversationTabRef(agentSession: ref)
        var chat = TabSnapshot(surface: 2, kind: .conversation, title: "Fix the login flow", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:vm-1", session: "s-1", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [page, chat])])
        daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let macTab = try #require(daemon.store.tab(surface: 1)), cloudTab = try #require(daemon.store.tab(surface: 2))
        var titles = TabTitleResolver(newTabPages: [macTab.id])
        titles.chatTitle = { _ in "Fix the login flow" }
        #expect(titles.isNewTabPage(macTab), "fixture: before, the Mac tab is its New Tab page")
        titles.fronted = { $0.id == macTab.id ? cloudTab : nil }
        #expect(!titles.isNewTabPage(macTab))
        #expect(titles.title(macTab) == titles.title(cloudTab))
        #expect(titles.title(macTab) != Strings.untitledBrowser)
    }
}
