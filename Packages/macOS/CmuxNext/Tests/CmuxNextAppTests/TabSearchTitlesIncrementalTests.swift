@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextDaemon
import Testing

/// Leo (ask-bdd706af47): opening a tab must not get slower with the number of workspaces. Every control snapshot
/// publish named every agent chat of every workspace for Search Tabs (`TabSearchFactsBuilder.titles`), under the
/// publisher's tracking, so a tab made in one workspace walked and resolved the tabs of all of them again.
///
/// With the publisher's cache the titles are kept per workspace: an unchanged publish resolves none, and a change in
/// one workspace resolves that workspace's chats only. The kept titles equal a fresh build.
@MainActor
struct TabSearchTitlesIncrementalTests {
    private static let count: UInt64 = 30

    private static func tree() -> DaemonTree {
        DaemonTree(workspaces: (1...count).map { id in
            var chat = TabSnapshot(surface: SurfaceID(rawValue: id), kind: .conversation, title: "chat \(id)")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: "s-\(id)", harness: "claude"))
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [chat, TabSnapshot(surface: SurfaceID(rawValue: 1000 + id), kind: .pty)])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)", screens: [screen])
        })
    }

    @Test func aChangeInOneWorkspaceResolvesOnlyItsChats() {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(snapshot: Self.tree())
        let cache = ControlWorkspaceInfoCache()
        final class Counter { var resolved = 0 }
        let counter = Counter()
        var resolver = TabTitleResolver()
        resolver.chatTitle = { [counter] tab in
            counter.resolved += 1
            return AgentChatTabTitle.untitled(tab.agentSession)
        }
        func resolved(_ body: () -> Void = {}) -> (Int, [String: String]) {
            body()
            let before = counter.resolved
            let titles = TabSearchFactsBuilder.titles(store.workspaces, resolver, cache: cache)
            return (counter.resolved - before, titles)
        }
        let (first, built) = resolved()
        #expect(first == Int(Self.count), "the first publish names every chat")
        let (unchanged, kept) = resolved()
        #expect(unchanged == 0, "an unchanged publish named \(unchanged) chats again")
        #expect(kept == built)
        let (changed, patched) = resolved { store.apply(.titleChanged(surface: 7, title: "renamed")) }
        #expect(changed == 1, "a change in one workspace named \(changed) of \(Self.count) chats again")
        #expect(patched == TabSearchFactsBuilder.titles(store.workspaces, resolver))
    }
}
