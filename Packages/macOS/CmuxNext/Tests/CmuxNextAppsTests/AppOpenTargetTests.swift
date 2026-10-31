import CmuxNextApps
import Foundation
import Testing

/// What opening an app shows, read from the App Store examples cmux ships
/// (`AppPlatform/store`, the folder the daemon lists): a scene page, a web
/// app in a browser tab, or nothing for a command-only app.
struct AppOpenTargetTests {
    private func shipped(_ name: String) throws -> AppManifest {
        let file = AppPlatformResources.storeExamples.appending(path: name).appending(path: "cmux-app.v2.json")
        return try #require(AppManifest.decode(try Data(contentsOf: file)), "\(name) decodes")
    }

    @Test func aWebAppOpensItsURLInABrowserTab() throws {
        #expect(try AppOpenTarget(shipped("cmux-docs")) == .web(URL(string: "https://cmux.com/docs")!))
    }

    @Test func aSceneAppOpensItsPanePage() throws {
        #expect(try AppOpenTarget(shipped("quick-links")) == .scenePane)
    }

    @Test func aCommandOnlyAppHasNothingToOpen() throws {
        #expect(try AppOpenTarget(shipped("standup")) == .none)
    }

    @Test func aScenePaneWinsOverAWebURL() throws {
        let manifest = try #require(AppManifest(json: [
            "id": "acme/both", "manifestVersion": 2,
            "implements": ["cmux.pane/1": ["export": "renderPane"]],
            "presentation": ["web": ["url": "https://acme.example/"]],
        ]))
        #expect(AppOpenTarget(manifest) == .scenePane)
    }

    @Test func onlyHTTPSWebAppsOpen() throws {
        let manifest = try #require(AppManifest(json: [
            "id": "acme/plain", "manifestVersion": 2,
            "presentation": ["web": ["url": "http://acme.example/"]],
        ]))
        #expect(AppOpenTarget(manifest) == .none)
    }
}
