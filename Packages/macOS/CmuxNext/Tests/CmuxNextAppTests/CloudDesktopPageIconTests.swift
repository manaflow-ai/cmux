@testable import CmuxNextApp
@testable import CmuxNextBridge
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
}
