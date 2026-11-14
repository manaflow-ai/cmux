import CmuxNextApps
import Testing

/// `render: web` (extensibility-DESIGN.md section 4, step 5): a web implementation survives the
/// manifest read instead of being dropped, so a client knows the pane is a page on `cmux-app://`.
struct AppWebPageManifestTests {
    /// codemirror's v2 shape: `runtime.web.root` and `implements["cmux.editor/1"].web`.
    @Test func aV2WebImplementationKeepsItsEntry() throws {
        let manifest = try #require(AppManifest(json: [
            "id": "cmux/codemirror", "manifestVersion": 2,
            "runtime": ["main": "dist/main.js", "web": ["root": "web/", "csp": "default-src 'self'"]],
            "implements": ["cmux.editor/1": ["web": "web/index.html", "symbol": "doc.text"]],
        ]))
        let page = try #require(manifest.webPages.first)
        #expect(page.interface == "cmux.editor/1")
        #expect(page.web == "web/index.html")
        #expect(page.isWebPage)
        #expect(!page.hasScene)
        #expect(manifest.scenePane == nil)
    }

    /// codemirror's v1 shape: `contributes.paneKinds[].web`.
    @Test func aV1PaneKindKeepsItsWebEntry() throws {
        let manifest = try #require(AppManifest(json: [
            "id": "cmux/codemirror", "manifestVersion": 1,
            "contributes": ["paneKinds": [["id": "editor", "web": "web/index.html"]]],
        ]))
        let page = try #require(manifest.webPages.first)
        #expect(page.isPane)
        #expect(page.web == "web/index.html")
    }

    @Test func aScenePaneIsNotAWebPage() throws {
        let manifest = try #require(AppManifest(json: [
            "id": "acme/scene", "manifestVersion": 2,
            "implements": ["cmux.pane/1": ["export": "renderPane"]],
        ]))
        #expect(manifest.webPages.isEmpty)
        #expect(manifest.scenePane != nil)
    }
}
