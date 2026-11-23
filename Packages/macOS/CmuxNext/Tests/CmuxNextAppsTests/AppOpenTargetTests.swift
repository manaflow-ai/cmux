import CmuxNextApps
import Foundation
import Testing

/// What opening an app shows, read from the App Store examples cmux ships: a
/// scene page, a web app in a browser tab, a New Tab page for a widget app, or nothing for a
/// command-only app.
/// The manifests come from their source, `samples/apps/<name>`: the shipped
/// copy (`AppPlatform/store`) is build output that a clean checkout lacks
/// until `build-web-bundles.sh` runs.
struct AppOpenTargetTests {
    private static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CmuxNextAppsTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // CmuxNext
        .deletingLastPathComponent() // macOS
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "samples/apps", directoryHint: .isDirectory)

    private func shipped(_ name: String) throws -> AppManifest {
        let file = Self.samples.appending(path: name).appending(path: "cmux-app.v2.json")
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

    /// Leo, 2026-11-22, on the store's Clock and Calendar widgets: "if i click install it means it
    /// works" / "i click install they dont do anything". A widget-only app's Open opens a New Tab
    /// page, where installing it placed the tile, instead of refusing with nothing to show.
    @Test func aShippedWidgetAppOpensTheNewTabPage() throws {
        let firstParty = Self.samples.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "first-party-apps", directoryHint: .isDirectory)
        for name in ["widget-clock", "widget-calendar"] {
            let file = firstParty.appending(path: name).appending(path: "cmux-app.json")
            let manifest = try #require(AppManifest.decode(try Data(contentsOf: file)), "\(name) decodes")
            #expect(AppOpenTarget(manifest) == .widget, "\(name)")
        }
    }

    @Test func aPaneOrWebAppWinsOverItsWidget() throws {
        let widget: AppJSON = ["export": "renderTile"]
        let pane = try #require(AppManifest(json: [
            "id": "acme/pane", "manifestVersion": 2,
            "implements": ["cmux.pane/1": ["export": "renderPane"], "cmux.widget/1": widget],
        ]))
        #expect(AppOpenTarget(pane) == .scenePane)
        let web = try #require(AppManifest(json: [
            "id": "acme/web", "manifestVersion": 2, "implements": ["cmux.widget/1": widget],
            "presentation": ["web": ["url": "https://acme.example/"]],
        ]))
        #expect(AppOpenTarget(web) == .web(URL(string: "https://acme.example/")!))
        let native = try #require(AppManifest(json: [
            "id": "acme/native", "manifestVersion": 2,
            "implements": ["cmux.pane/1": ["native": "home"], "cmux.widget/1": widget],
        ]))
        #expect(AppOpenTarget(native) == .none, "a native pane opens through its show action")
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

    @Test func aRemotePaneOpensItsRunningInstance() throws {
        var record = AppRecord(manifest: try shipped("hello-deploy"), tier: .unverified, installed: true, source: .user)
        #expect(AppOpenTarget(record) == .notDeployed, "installed but not deployed yet")
        record.instance = AppInstance(id: "inst_1", target: "self-hosted:build-01", state: .deploying, url: nil)
        #expect(AppOpenTarget(record) == .notDeployed, "still deploying")
        record.instance = AppInstance(id: "inst_1", target: "self-hosted:build-01", state: .running,
                                      url: URL(string: "http://100.64.0.9:49153/"))
        #expect(AppOpenTarget(record) == .web(URL(string: "http://100.64.0.9:49153/")!))
    }

    @Test func theInstanceDecodesFromTheSupervisorsListRow() throws {
        let manifest = try shipped("hello-deploy")
        let json: AppJSON = [
            "id": .string(manifest.id), "manifest": manifest.raw, "installed": true,
            "instance": ["id": "inst_9", "target": "self-hosted:ops@build-01", "state": "running",
                         "url": "http://100.64.0.9:49153/", "app": .string(manifest.id), "started_ms": 1],
        ]
        let record = try #require(AppRecord(json: json))
        #expect(record.instance == AppInstance(id: "inst_9", target: "self-hosted:ops@build-01", state: .running,
                                               url: URL(string: "http://100.64.0.9:49153/")))
    }
}
