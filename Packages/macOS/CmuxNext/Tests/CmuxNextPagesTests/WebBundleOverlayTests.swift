import Foundation
@testable import CmuxNextPages
import Testing

/// The served web update (plans/cmux-next/web-ota.md): a scheme handler keeps its bundled root and
/// gets the same folder inside the active update; with none (or outside a registered bundle) it
/// serves the bundle, and a request during the launch check waits for it.
struct WebBundleOverlayTests {
    static let bundledPages = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextPages.bundle/pages", isDirectory: true)
    static let bundledPane = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextAgentPane.bundle/agent-pane", isDirectory: true)
    // Not a repository path, so ci-target-graph.py does not count it as a read of the real bundle.
    static let paneOutput = "fixture/agent-pane"
    static let tree = URL(fileURLWithPath: "/Support/web-updates/trees/abc", isDirectory: true)

    static func overlay() -> WebBundleOverlay {
        let overlay = WebBundleOverlay(bases: [.init(bundled: bundledPages.path, output: WebBundleOverlay.pagesOutput)])
        overlay.register(bundled: bundledPane, output: paneOutput)
        return overlay
    }

    @Test func withNoUpdateTheBundleIsServed() async {
        let overlay = Self.overlay()
        let settings = Self.bundledPages.appending(path: "settings", directoryHint: .isDirectory)
        #expect(await overlay.root(for: settings) == settings)
    }

    @Test func anActiveUpdateServesItsCopyOfTheSameFolder() async {
        let overlay = Self.overlay()
        #expect(overlay.activate(Self.tree))
        #expect(!overlay.activate(Self.tree))
        let settings = await overlay.root(for: Self.bundledPages.appending(path: "settings", directoryHint: .isDirectory))
        #expect(settings.path == Self.tree.path + "/" + WebBundleOverlay.pagesOutput + "/settings")
        #expect(await overlay.root(for: Self.bundledPane).path
            == Self.tree.path + "/" + Self.paneOutput)
        // A root no bundle registered (an app page's own folder) keeps its files.
        let other = URL(fileURLWithPath: "/Users/me/app-page", isDirectory: true)
        #expect(await overlay.root(for: other) == other)
        // A sibling whose name only starts like a registered folder is not inside it.
        let sibling = URL(fileURLWithPath: Self.bundledPages.path + "-old/settings", isDirectory: true)
        #expect(await overlay.root(for: sibling) == sibling)
        #expect(overlay.activate(nil))
        #expect(await overlay.root(for: Self.bundledPane) == Self.bundledPane)
    }

    /// One React for every tree: Agent Activity imports React from the pages' `_shared`
    /// (`cmux-page://cmux.shared/`), so once the app registers it both come from the active update.
    @Test func agentActivityAndTheSharedChunksComeFromTheSameUpdate() async {
        let overlay = Self.overlay()
        let activity = URL(fileURLWithPath: "/App.app/Contents/Resources/CmuxNextAgentActivity.bundle/agent-activity", isDirectory: true)
        let shared = Self.bundledPages.appending(path: "_shared", directoryHint: .isDirectory)
        overlay.activate(Self.tree)
        // Unregistered, the page stays bundled while its React would come from the update.
        #expect(await overlay.root(for: activity) == activity)
        overlay.register(bundled: activity, output: WebBundleOverlay.agentActivityOutput)
        #expect(await overlay.root(for: shared).path == Self.tree.path + "/" + WebBundleOverlay.pagesOutput + "/_shared")
        #expect(await overlay.root(for: activity).path == Self.tree.path + "/" + WebBundleOverlay.agentActivityOutput)
    }

    /// A frozen page kept across a swap: its document pinned the tree it loaded from, so
    /// its lazy chunk and its `cmux.shared` files still come from there, never from the new tree, and
    /// the updater keeps that tree until the document goes.
    @Test func anOldFrozenDocumentLoadsItsLazyChunkFromItsOwnTree() async {
        let overlay = Self.overlay()
        let old = Self.tree
        let new = URL(fileURLWithPath: "/Support/web-updates/trees/def", isDirectory: true)
        overlay.activate(old)
        var pin: WebBundleOverlay.Pin? = await overlay.pin()
        #expect(overlay.activate(new))
        let chunks = Self.bundledPages.appending(path: "settings/assets", directoryHint: .isDirectory)
        let shared = Self.bundledPages.appending(path: "_shared", directoryHint: .isDirectory)
        let pages = "/" + WebBundleOverlay.pagesOutput
        #expect(await overlay.root(for: chunks).path == new.path + pages + "/settings/assets")
        #expect(Set(overlay.liveTrees.map(\.path)) == [old.path, new.path])
        #expect(await overlay.root(for: chunks, pin: pin).path == old.path + pages + "/settings/assets")
        #expect(await overlay.root(for: shared, pin: pin).path == old.path + pages + "/_shared")
        pin = nil
        #expect(overlay.liveTrees.map(\.path) == [new.path], "the tree of a gone document is still kept")
    }

    /// A document's own load takes the pin; its later requests (a chunk, an image) do not.
    @Test func onlyTheMainDocumentRequestPinsATree() throws {
        let document = try #require(URL(string: "cmux-page://settings/index.html#general"))
        let chunk = try #require(URL(string: "cmux-page://settings/assets/section.js"))
        #expect(PageSchemeHandler.isMainDocument(document, mainDocument: URL(string: "cmux-page://settings/index.html")))
        #expect(!PageSchemeHandler.isMainDocument(chunk, mainDocument: document))
        #expect(!PageSchemeHandler.isMainDocument(document, mainDocument: nil))
    }

    @Test func anEscapingOutputIsNotRegistered() async {
        let overlay = WebBundleOverlay(bases: [])
        overlay.register(bundled: Self.bundledPane, output: "../../etc")
        overlay.activate(Self.tree)
        #expect(await overlay.root(for: Self.bundledPane) == Self.bundledPane)
    }

    @Test func aRequestDuringTheLaunchCheckWaitsForIt() async {
        let overlay = Self.overlay()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let tree = Self.tree
        overlay.load {
            for await _ in gate { break }
            return tree
        }
        // task-owner: the test's one waiting request
        let request = Task { await overlay.root(for: Self.bundledPane) }
        open.yield()
        open.finish()
        #expect(await request.value.path.hasPrefix(Self.tree.path + "/"))
    }
}
