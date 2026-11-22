@testable import CmuxNextBridge
import CmuxNextRemoteView
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-22, on a Cloud desktop's workspace hover card: the machine showed twice, "chat-800dd… Desktop" (the
/// card's title over a globe) and "chat-800dd…" (its one tab, with the Cloud icon and "remote-view" as its place).
/// The workspace's name is its one tab's plus "Desktop", so the tab row is the name; a cmux page has no place.
@MainActor @Suite struct CloudDesktopHoverCardOneRowTests {
    @Test func aCmuxPageHasNoPlaceOnItsRow() throws {
        let desktop = try #require(RemoteViewTabRecord(host: "chat-800dd580cab0487c", target: .virtual, cloudDesktop: true, cloudRd: true))
        #expect(SidebarMapping.pageHost(desktop.url.absoluteString) == "remote-view")
        #expect(SidebarMapping.webHost(desktop.url.absoluteString) == nil)
        #expect(SidebarMapping.webHost("https://www.github.com/manaflow-ai") == "github.com")
        #expect(SidebarMapping.webHost("http://localhost:5173/") == "localhost")
    }

    @Test func aWorkspaceNamedAfterItsOneTabPlusAWordShowsOneRow() {
        let rule = WorkspaceHoverCardTitle.unlessRepeated
        #expect(!rule.showsTitle("chat-800dd580cab0487c Desktop", tabTitles: ["chat-800dd580cab0487c"], expanded: false))
        #expect(!rule.showsTitle("Claude Code", tabTitles: ["claude code"], expanded: false))
        #expect(rule.showsTitle("todo-app", tabTitles: ["todo"], expanded: false))
        #expect(rule.showsTitle("chat Desktop", tabTitles: ["chat", "zsh"], expanded: false))
        #expect(rule.showsTitle("chat-800dd580cab0487c Desktop", tabTitles: ["chat-800dd580cab0487c"], expanded: true))
    }
}
