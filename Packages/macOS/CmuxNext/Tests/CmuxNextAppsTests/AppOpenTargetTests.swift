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
