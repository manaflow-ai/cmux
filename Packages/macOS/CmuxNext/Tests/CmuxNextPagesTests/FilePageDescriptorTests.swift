import Foundation
import Testing
@testable import CmuxNextPages

/// diff-host S6 and S7: the markdown and code editor pages are first-party pages of the one
/// webviews-app build, each with its own entry, CSP, dynamic prefixes and page commands.
@MainActor
@Suite struct FilePageDescriptorTests {
    @Test func bothFilePagesAreFirstPartyPagesOfTheWebviewsAppBuild() {
        #expect(PageID.isFirstParty(PageDescriptor.markdown.id))
        #expect(PageID.isFirstParty(PageDescriptor.editor.id))
        #expect(PageDescriptor.editor.id == "cmux.editor")
        #expect(PageDescriptor.markdown.resource == "webviews-app" && PageDescriptor.markdown.entry == "markdown-page.html")
        #expect(PageDescriptor.editor.resource == "webviews-app" && PageDescriptor.editor.entry == "editor-page.html")
        #expect(PageDescriptor.editor.namespaces == ["cmux.editor."])
        #expect(PageDescriptor.markdown.namespaces == ["cmux.markdown."])
        #expect(!PageDescriptor.editor.admits("cmux.markdown.save"))
        #expect(!PageDescriptor.markdown.admits("cmux.editor.save"))
    }

    /// The editor's policy is exactly what webviews/test/editor-csp.test.ts runs Monaco under; the
    /// markdown page stays strict (Vega uses vega-interpreter, images come from its own origin).
    @Test func theEditorAddsOnlyWebAssemblyAndTheMarkdownPageStaysStrict() {
        #expect(PageDescriptor.editor.csp.header
            == "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:")
        #expect(PageDescriptor.markdown.csp == .strict)
        #expect(!PageDescriptor.markdown.csp.header.contains("unsafe-eval"))
        #expect(!PageDescriptor.editor.csp.header.contains("'unsafe-eval'"))
        #expect(!PageDescriptor.editor.csp.header.contains("connect-src"))
    }

    /// Local images, the diagram libraries and host-fetched remote images are the markdown page's
    /// generated resources; the editor has none.
    @Test func theMarkdownPageServesImagesAndLibrariesFromItsOwnOrigin() {
        #expect(PageDescriptor.markdown.dynamicPrefixes == [MarkdownPageResource.asset, MarkdownPageResource.library,
                                                            MarkdownPageResource.remoteImage])
        #expect(MarkdownPageResource.remoteImage == "__image")
        #expect(PageDescriptor.editor.dynamicPrefixes.isEmpty)
    }

    @Test func eachFilePageTakesTheCommandsItsReadmeLists() {
        // back and forward are the shared page commands (PageNativeOp.commands), as the trunk has them.
        #expect(PageDescriptor.markdown.commands.isSuperset(of: ["save", "back", "forward", "link", "zoomIn", "zoomOut", "zoomReset"]))
        #expect(PageDescriptor.markdown.commands.isSuperset(of: MarkdownPageCommand.all))
        #expect(EditorPageCommand.all == ["save", "find", "findNext", "findPrevious", "useSelectionForFind", "hideFind",
                                          "replace", "gotoLine", "zoomIn", "zoomOut", "zoomReset", "editorAction"])
        #expect(PageDescriptor.editor.commands == PageNativeOp.commands.union(EditorPageCommand.all))
        #expect(!PageDescriptor.editor.commands.contains(DiffPageCommand.nextHunk))
    }

    /// The launch call registers the one webviews-app directory for both pages; a later call
    /// cannot move them.
    @Test func theFilePagesAreServedFromTheRegisteredAppRoot() throws {
        let resources = FileManager.default.temporaryDirectory.appending(path: "cmux-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = PageDescriptor.diffRoot(inAppResources: resources)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(PageDescriptor.registerFilePageRoots(appResources: resources) == root)
        #expect(PageWebView.servedRoot(for: .markdown) == root)
        #expect(PageWebView.servedRoot(for: .editor) == root)
        PageDescriptor.registerFilePageRoots(appResources: FileManager.default.temporaryDirectory.appending(path: "cmux-other"))
        #expect(PageWebView.servedRoot(for: .editor) == root)
        #expect(PageDescriptor.markdownLibraries(inAppResources: resources).path.hasSuffix("/markdown-viewer"))
    }
}
