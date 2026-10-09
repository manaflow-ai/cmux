import Foundation
import Testing
@testable import CmuxNextApps

/// The shipped first-party apps carry manifest v2 `presentation` (app-screens.md 4,
/// app-platform.md 16): Home, App Store and CodeRouter decode with the same
/// fields as any app (the supervisor sends these manifests in `apps-list`), so
/// the sidebar builds its top band from them.
@MainActor
@Suite struct AppPresentationTests {
    private func shipped(_ id: String) throws -> AppManifest {
        try #require(AppPlatformResources.firstPartyManifests().first { $0.manifest.id == id }?.manifest, "\(id)")
    }

    @Test func homeResolvesWithTheAppColumnScreen() throws {
        let presentation = try #require(try shipped("cmux/home").presentation)
        #expect(presentation.screen == .appColumn)
        #expect(presentation.tab)
        #expect(presentation.primaryInput == "home.composer")
        #expect(presentation.sidebarItem?.section == "top" && presentation.sidebarItem?.order == 0)
    }

    @Test func appStoreAndCodeRouterResolveWithTheAppScreen() throws {
        for id in ["cmux/app-store", "cmux/coderouter"] {
            let manifest = try shipped(id)
            #expect(manifest.presentation?.screen == .app, "\(id)")
            #expect(manifest.presentation?.tab == true, "\(id)")
        }
    }

    /// CodeRouter's v2 manifest names its scene section and its scene pane;
    /// Home's pane is native (cmux draws it, no scene).
    @Test func codeRouterHasASceneSectionAndPaneAndHomeIsNative() throws {
        let coderouter = try shipped("cmux/coderouter")
        #expect(coderouter.sections.first?.hasScene == true)
        #expect(coderouter.scenePane != nil)
        #expect(coderouter.presentation?.sidebarItem?.order == 20)
        #expect(try shipped("cmux/home").scenePane == nil)
    }

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
