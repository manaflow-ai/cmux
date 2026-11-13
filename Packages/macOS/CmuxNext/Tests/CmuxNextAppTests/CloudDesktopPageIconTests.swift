@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextIcons
import CmuxNextRemoteView
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-12, on a Cloud machine's row in the sidebar (its focused tab is the machine's desktop,
/// `cmux://remote-view?...&via=cloud-rd`): "it's using the old crummy icon". A cmux page is no site, so its row
/// never draws the no-favicon globe; a Cloud desktop wears the Cloud icon the machine has on every other surface.
@MainActor @Suite struct CloudDesktopPageIconTests {
    static let cloudDesktop = RemoteViewTabRecord(host: "chat-800dd580cab0487c", target: .virtual, cloudDesktop: true, cloudRd: true)

    /// The tab strip's icon for a Cloud desktop is the Cloud icon; another computer's desktop keeps the remote mark.
    @Test func aCloudDesktopTabWearsTheCloudIcon() throws {
        let cloud = try #require(Self.cloudDesktop)
        #expect(BrowserTabIconState.pageIcon(cloud.url) == .cloud)
        let mac = try #require(RemoteViewTabRecord(host: "studio"))
        #expect(BrowserTabIconState.pageIcon(mac.url) == .machineRemote)
    }

    /// A row whose page is a cmux page with no favicon draws no site globe.
    @Test func aCmuxPageRowDrawsNoSiteGlobe() throws {
        let cloud = try #require(Self.cloudDesktop)
        let row = try SidebarFaviconPlaceholderTests.row(id: 1, url: cloud.url.absoluteString, hasFavicon: false)
        #expect(row.icon != .pagePlaceholder, "a Cloud desktop row drew the site globe")
    }

    /// The page face's icon is the row's icon and its hover card tab's: the Cloud icon, where the globe was.
    @Test func aCloudDesktopRowAndItsTabWearTheCloudIcon() throws {
        let cloud = try #require(Self.cloudDesktop)
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .browser, title: "chat-800dd580cab0487c",
                                                                         url: cloud.url.absoluteString)])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        let workspace = try #require(store.workspaces.first)
        let row = SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
            .init(title: tab.titleText, icon: BrowserTabIconState.pageIcon(tab.url.flatMap { URL(string: $0) }))
        })
        #expect(row.icon == .page(.cloud))
        #expect(row.tabs.first?.pageIcon == .cloud)
    }
}
