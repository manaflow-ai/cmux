import CmuxNextApps
import Testing

/// `app.open` routes: a scene pane opens the app page, a native pane (Cloud, App Store, Home)
/// opens the page cmux draws for it, and an app with no pane has no page.
struct AppPaneRouteTests {
    private func manifest(_ pane: String) throws -> AppManifest {
        let text = #"{"id":"cmux/x","manifestVersion":2,"implements":{"cmux.pane/1":"# + pane + "}}"
        return try #require(AppManifest(json: AppJSON.parse(text)))
    }

    @Test func aNativePaneRoutesToItsNativePage() throws {
        // The Cloud app's manifest (first-party-apps/cloud): `native: "cloud"`, no scene export.
        let cloud = try manifest(#"{"native":"cloud","title":{"en":"Cloud"},"symbol":"cloud"}"#)
        #expect(AppPaneRoute(cloud) == .native("cloud"))
    }

    @Test func aScenePaneRoutesToTheAppPage() throws {
        let app = try manifest(#"{"export":"renderPane","title":{"en":"Agents"}}"#)
        guard case .scene(let pane) = AppPaneRoute(app) else {
            Issue.record("a scene pane did not route to its scene")
            return
        }
        #expect(pane.export == "renderPane")
    }

    @Test func anAppWithoutAPaneHasNoPage() throws {
        let app = try #require(AppManifest(json: AppJSON.parse(#"{"id":"cmux/x","manifestVersion":2,"implements":{}}"#)))
        #expect(AppPaneRoute(app) == AppPaneRoute.none)
    }
}
