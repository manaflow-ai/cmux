#if os(iOS) && DEBUG
import CmuxMobileFeed
import CmuxMobileModel
import Foundation

/// `-cmux-mobile-demo feed-closed-*`: the Feed with its mock rows on the mock Mac Studio, whose
/// open tabs come from the phone's workspace list the way the Mac's tree feeds them live
/// (`LiveCoordinator.apply`). Each scene closes tabs through the store's own close paths.
extension DemoDriver {
    nonisolated static let feedClosedTabsNames: Set<String> = [
        "feed-closed-before", "feed-closed-tab", "feed-closed-workspace", "feed-closed-launch",
        "feed-closed-ask", "feed-closed-empty", "feed-closed-tabs",
    ]

    static let feedDemoMac = "mac-studio"

    func feedClosedTabs(_ name: String) async {
        let feed = FeedStore.shared
        // The mock rows name no Mac; the live ones do (`FeedItem.macID`).
        feed.replaceAll(feed.items.map { item in
            var item = item
            item.macID = Self.feedDemoMac
            return item
        })
        shell.tab = .feed
        let echo = { (complete: Bool) in
            let mac = self.shell.store.workspaces.filter { $0.macID == Self.feedDemoMac }
            feed.setOpenTabs(FeedOpenTabs(workspaces: mac, complete: complete), macID: Self.feedDemoMac)
        }
        switch name {
        case "feed-closed-before":
            echo(true)
        case "feed-closed-tab":
            // The cmux-next-ios workspace's Claude tab closed; its build tab stays open.
            shell.store.removeTab("t-ios-claude", from: "ws-ios")
            echo(true)
        case "feed-closed-workspace":
            // The cmux.com workspace closed with its Codex tab: its pending approval stays.
            shell.store.removeWorkspace("ws-web")
            echo(true)
        case "feed-closed-launch":
            // Launch, before the Mac answers: the snapshot lists only the cmux workspace, whose
            // Claude tab was closed before the app last saw it. Workspaces it doesn't list keep
            // their rows until the Mac's own tree says.
            shell.store.removeTab("t-claude", from: "ws-cmux")
            let cmux = shell.store.workspaces.filter { $0.id == "ws-cmux" }
            feed.setOpenTabs(FeedOpenTabs(workspaces: cmux, complete: false), macID: Self.feedDemoMac)
        case "feed-closed-ask":
            // Every tab closed while two chat asks still wait: only the asks stay.
            for workspace in ["ws-cmux", "ws-web", "ws-ios"] { shell.store.removeWorkspace(workspace) }
            echo(true)
        case "feed-closed-empty":
            for workspace in ["ws-cmux", "ws-web", "ws-ios"] { shell.store.removeWorkspace(workspace) }
            echo(true)
            for item in feed.items where item.needsYou { feed.resolveElsewhere(item.id, text: "Answered") }
        case "feed-closed-tabs":
            // The recording: everything open, then a tab, a workspace, the rest, the asks answered.
            echo(true)
            await pause(3)
            shell.store.removeTab("t-ios-claude", from: "ws-ios")
            echo(true)
            await pause(3)
            shell.store.removeWorkspace("ws-web")
            echo(true)
            await pause(3)
            shell.store.removeWorkspace("ws-cmux")
            echo(true)
            await pause(3)
            for item in feed.items where item.needsYou { feed.resolveElsewhere(item.id, text: "Answered") }
        default:
            break
        }
    }
}
#endif
