@testable import CmuxNextApps
import Foundation
import Testing
import WebKit

/// An embedded external web app (`cmux.pane/1` `embed`): the record carries the daemon's url,
/// origins and profile; the pane is on the app's own data store and stays on the declared origins
/// (the same table as cmux-app-manifest tests/embed_pane.rs).
@MainActor
struct AppEmbedPaneTests {
    private static let profile = "0b5a4c3d-2e1f-8a9b-8c7d-6e5f4a3b2c1d"

    private func record() -> AppRecord? {
        let manifest: AppJSON = .object([
            "manifestVersion": .number(2), "id": .string("local/figma"), "name": .string("Figma"),
            "version": .string("1.0.0"),
            "implements": .object(["cmux.pane/1": .object(["embed": .object(["url": .string("https://www.figma.com/files")])])]),
        ])
        let page: AppJSON = .object([
            "interface": .string("cmux.pane/1"), "url": .string("https://www.figma.com/files"),
            "origins": .array([.string("https://www.figma.com"), .string("https://*.figma.com"),
                               .string("https://accounts.google.com")]),
            "profile": .string(Self.profile), "symbol": .string("paintbrush"),
        ])
        return AppRecord(json: .object(["id": .string("local/figma"), "manifest": manifest, "installed": .bool(true),
                                        "embed_pages": .array([page])]))
    }

    @Test func theRecordCarriesTheEmbedAndOpensAsAPane() throws {
        let app = try #require(record())
        let embed = try #require(app.embedPane)
        #expect(embed.url.absoluteString == "https://www.figma.com/files")
        #expect(embed.profile == UUID(uuidString: Self.profile))
        #expect(app.manifest.embedPane)
        #expect(AppOpenTarget(app.manifest) == .scenePane)
    }

    @Test func navigationStaysOnDeclaredOrigins() throws {
        let embed = try #require(record()?.embedPane)
        for ok in ["https://www.figma.com/file/abc?x=1", "https://static.figma.com/a.js",
                   "https://ACCOUNTS.google.com/o/oauth2", "https://accounts.google.com:443/"] {
            #expect(embed.allows(try #require(URL(string: ok))), "\(ok)")
        }
        for refused in ["https://figma.com.evil.com/", "https://evilfigma.com/", "https://mail.google.com/",
                        "http://www.figma.com/", "https://www.figma.com:8443/", "https://user@www.figma.com/",
                        "file:///etc/passwd"] {
            #expect(!embed.allows(try #require(URL(string: refused))), "\(refused)")
        }
    }

    @Test func thePaneUsesTheAppsOwnDataStore() throws {
        let embed = try #require(record()?.embedPane)
        let host = AppEmbedPaneHost(page: embed)
        defer { host.close() }
        let store = host.view.configuration.websiteDataStore
        #expect(store.identifier == embed.profile)
        #expect(store.isPersistent)
        #expect(store != WKWebsiteDataStore.default())
        #expect(!host.permits(URL(string: "https://example.com/"), mainFrame: true))
        #expect(host.permits(URL(string: "https://example.com/"), mainFrame: false))
    }
}
