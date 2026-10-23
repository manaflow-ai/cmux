import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextSettings
import Testing
import UserNotifications

/// The system banner for a tab an agent marked (tab-attention-v1): one per request, none for marks
/// made before launch, withdrawn when the mark clears, and its Show (or a click) goes to the tab
/// through the one shared Go to; posting it moves nothing.
@MainActor @Suite(.serialized)
struct AttentionBannerTests {
    private static func item(_ tab: String, at: UInt64, reason: String = "Log in to GitHub") -> AgentPaneAttentionTabs.Item {
        AgentPaneAttentionTabs.Item(tabId: tab, reason: reason, workspaceTitle: "cmux next", tabTitle: "GitHub", atMs: at)
    }

    @Test func aBannerPostsPerNewRequestAndClearsWithTheMark() {
        let login = Self.item("tab_1", at: 1_000)
        #expect(NotificationCenterService.attentionChanges(previous: nil, current: [login]) == ([], []),
                "a mark made before launch posts nothing")
        #expect(NotificationCenterService.attentionChanges(previous: [], current: [login]) == ([login], []))
        #expect(NotificationCenterService.attentionChanges(previous: [login], current: [login]) == ([], []),
                "the same request never posts twice")
        let again = Self.item("tab_1", at: 2_000, reason: "Approve the scopes")
        let replaced = NotificationCenterService.attentionChanges(previous: [login], current: [again])
        #expect(replaced.post == [again], "a new request on the tab posts again")
        #expect(replaced.withdraw == [NotificationCenterService.attentionBannerID(login)])
        #expect(NotificationCenterService.attentionChanges(previous: [again], current: []).withdraw
            == [NotificationCenterService.attentionBannerID(again)], "a cleared mark takes its banner back")
    }

    @Test func theBannerNamesItsTabAndNothingElse() {
        let id = NotificationCenterService.attentionBannerID(Self.item("tab_0f3c", at: 42))
        #expect(id == "cmux-attention.42.tab_0f3c")
        #expect(NotificationCenterService.attentionTab(banner: id) == "tab_0f3c")
        for other in ["cmux-notification-7", "cmux-attention.", "cmux-attention.x.tab_1", "cmux-attention.42.", "attention.42.tab_1"] {
            #expect(NotificationCenterService.attentionTab(banner: other) == nil, "\(other)")
        }
    }

    @Test func showGoesToTheMarkedTabThroughGoTo() {
        _ = NSApplication.shared
        let shared = AgentPaneAttentionTabs.shared
        let (items, onOpen) = (shared.items, shared.onOpen)
        defer { shared.items = items; shared.onOpen = onOpen }
        var shown: [String] = []
        shared.onOpen = { id in shown.append(id); return true }
        shared.items = [Self.item("tab_1", at: 1_000)]
        let service = NotificationCenterService()
        service.desktopPostingEnabled = false
        service.attentionMarksChanged([])
        service.attentionMarksChanged(shared.items)
        #expect(shown.isEmpty, "a mark and its banner move nothing")
        #expect(service.showAttention(banner: "cmux-attention.1000.tab_1"))
        #expect(shown == ["tab_1"])
        #expect(!service.showAttention(banner: "cmux-notification-3"), "other banners keep their own path")
    }

    @Test func theBannerOffersShow() {
        let category = DesktopNotifier.attentionBannerCategory()
        #expect(category.identifier == DesktopNotifier.attentionCategory)
        #expect(category.actions.map(\.identifier) == [DesktopNotifier.showAction])
        #expect(category.actions.first?.options.contains(.foreground) == true)
    }
}
