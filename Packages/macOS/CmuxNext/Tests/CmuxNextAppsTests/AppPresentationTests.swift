import Foundation
import Testing
@testable import CmuxNextApps

/// Manifest v2 `presentation` and `contributes.toolbarItems` decode (app-screens.md 4,
/// app-platform.md 16 and 17).
@MainActor
@Suite struct AppPresentationTests {
    @Test func aWebAppPresentationReadsItsURLAndProfile() throws {
        let json = try AppJSON.parse(Data(#"{"web":{"url":"https://mail.google.com/","origins":["https://accounts.google.com"]},"screen":"app"}"#.utf8))
        let presentation = try #require(AppPresentation(json: json))
        #expect(presentation.web?.url.host() == "mail.google.com")
        #expect(presentation.web?.profile == "app" && presentation.web?.origins == ["https://accounts.google.com"])
        #expect(presentation.screen == .app && !presentation.tab && presentation.sidebarItem == nil)
    }

    @Test func toolbarItemsReadButtonsMenusViewsAndOverrides() throws {
        let json = try AppJSON.parse(Data(#"""
        {"contributes":{"toolbarItems":[
          {"id":"compose","kind":"button","title":"Compose","icon":{"symbol":"square.and.pencil"},"action":{"op":"x.compose","args":{"draft":true}}},
          {"id":"more","kind":"menu","title":{"en":"More","ja":"その他"},"items":[{"title":"Refresh","action":{"op":"x.refresh"}}]},
          {"id":"meter","kind":"view","title":"Usage","width":120,"order":5},
          {"id":"back","kind":"button","title":"Back","action":{"op":"x.back"},"overrides":"nav.back"},
          {"id":"broken","kind":"slider","title":"Nope"}]}}
        """#.utf8))
        let items = AppToolbarItem.list(json)
        #expect(items.map(\.id) == ["compose", "more", "meter", "back"])
        #expect(items[0].action == AppToolbarItem.Action(op: "x.compose", args: .object(["draft": .bool(true)])))
        #expect(items[1].kind == .menu && items[1].items.map(\.action.op) == ["x.refresh"])
        #expect(items[2].kind == .view && items[2].width == 120 && items[2].order == 5)
        #expect(items[3].overrides == "nav.back")
    }
}
