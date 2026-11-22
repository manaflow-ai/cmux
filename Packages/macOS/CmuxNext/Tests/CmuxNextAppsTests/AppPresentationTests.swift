import Foundation
import Testing
@testable import CmuxNextApps

/// The shipped first-party apps carry manifest v2 `presentation` (app-screens.md 4,
/// app-platform.md 16): Home, App Store and CodeRouter resolve in the registry
/// with the same fields as any app, so the sidebar builds its top band from them.
@MainActor
@Suite struct AppPresentationTests {
    private func registry() async throws -> AppRegistry {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-app-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = AppRegistry(directory: root, bundledRoot: root.appending(path: "no-samples"))
        await registry.load()
        return registry
    }

    @Test func homeResolvesWithTheAppColumnScreen() async throws {
        let home = try #require(try await registry().app("cmux/home"))
        let presentation = try #require(home.manifest.presentation)
        #expect(presentation.screen == .appColumn)
        #expect(presentation.tab)
        #expect(presentation.primaryInput == "home.composer")
        #expect(presentation.sidebarItem?.section == "top" && presentation.sidebarItem?.order == 0)
        #expect(home.isInstalled)
    }

    @Test func appStoreAndCodeRouterResolveWithTheAppScreen() async throws {
        let registry = try await registry()
        for id in ["cmux/app-store", "cmux/coderouter"] {
            let app = try #require(registry.app(id), "\(id)")
            #expect(app.manifest.presentation?.screen == .app, "\(id)")
            #expect(app.manifest.presentation?.tab == true, "\(id)")
        }
    }

    /// CodeRouter keeps its v1 manifest for the prototype engine (its
    /// contributions still mount) and takes presentation from v2.
    @Test func codeRouterKeepsItsV1ContributionsAndTakesV2Presentation() async throws {
        let app = try #require(try await registry().app("cmux/coderouter"))
        #expect(!app.manifest.contributes.entries.isEmpty)
        #expect(app.manifest.presentation?.sidebarItem?.order == 20)
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
