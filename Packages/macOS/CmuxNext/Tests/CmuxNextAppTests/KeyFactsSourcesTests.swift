import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextFilesUI
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing
import WebKit

/// Each source of the key router's cached key facts, through the real router under an equal
/// focus: an input the lookups are built from rebuilds them once and names itself; a flag of an object a build
/// found follows that object on the next key with no rebuild. A unit test has no terminal, browser or page pane
/// for a build to find, so the copy mode, suggestion list, readiness and Chromium page window tests put those
/// objects in the cache as a build would (``KeyContextCacheTests/Harness/seed(_:)``) and read them through the
/// router's own live reads.
@MainActor @Suite(.serialized)
struct KeyFactsSourcesTests {
    // MARK: Inputs the lookups are built from

    @Test func theFileExplorerTakingTheKeyboardRebuildsTheFacts() throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let list = FileExplorerTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        try #require(harness.shell.contentView).addSubview(list)
        #expect(!harness.facts().fileExplorerFocused)
        let builds = harness.builds, mark = harness.mark()
        try #require(harness.shell.makeFirstResponder(list))
        #expect(harness.facts().fileExplorerFocused, "the file explorer's keyboard did not reach the facts")
        #expect(harness.builds == builds + 1)
        #expect(harness.router.keyFactsCache.lastInvalidation == harness.expected(.firstResponder, since: mark))
    }

    @Test func workspacesAsTabsRebuildsTheFacts() throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(SidebarTunables.all)
        let key = SidebarTunables.workspacesAsTabs.key
        store.set(key, nil)
        defer { store.set(key, nil) }
        #expect(!harness.facts().workspacesAsTabs)
        let builds = harness.builds
        store.set(key, .bool(true))
        #expect(harness.facts().workspacesAsTabs, "workspaces as tabs did not reach the facts")
        #expect(harness.builds == builds + 1)
        #expect(harness.router.keyFactsCache.lastInvalidation == .workspacesAsTabs)
    }

    @Test func aTopPageRebuildsTheFacts() throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        #expect(harness.facts().pageID == nil)
        let builds = harness.builds, mark = harness.mark()
        _ = try Self.showTopPage(KeyRouter.markdownPageID, in: harness)
        #expect(harness.facts().pageID == KeyRouter.markdownPageID, "the facts did not find the top page's page")
        #expect(harness.builds == builds + 1)
        #expect(harness.router.keyFactsCache.lastInvalidation == harness.expected(.topPage, since: mark))
    }

    // MARK: Flags of the objects a build found, read on every key

    @Test func thePagesListAndEditableFocusFollowTheReadiness() throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let readiness = PageInputReadiness(configuration: WKWebViewConfiguration())
        let builds = harness.seed(KeyRouter.FactSources(readiness: readiness))
        #expect(!harness.facts().listFocus)
        readiness.reportList(true)
        #expect(harness.facts().listFocus, "a list taking focus in the page did not reach the facts")
        readiness.reportEditing(true)
        #expect(harness.facts().pageEditableFocused, "an editable element taking focus did not reach the facts")
        readiness.reportList(false)
        readiness.reportEditing(false)
        let facts = harness.facts()
        #expect(!facts.listFocus)
        #expect(!facts.pageEditableFocused)
        #expect(harness.builds == builds)
    }

    @Test func theSuggestionListFollowsTheAddressBar() throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let bar = FakeSuggestions()
        let builds = harness.seed(KeyRouter.FactSources(suggestions: bar))
        #expect(!harness.facts().omnibarListOpen)
        bar.isShowingSuggestions = true
        #expect(harness.facts().omnibarListOpen, "the suggestion list opening did not reach the facts")
        bar.isShowingSuggestions = false
        #expect(!harness.facts().omnibarListOpen)
        #expect(harness.builds == builds)
    }

    @Test func copyModeFollowsTheTerminal() throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let terminal = FakeCopyMode()
        let builds = harness.seed(KeyRouter.FactSources(copyMode: terminal))
        #expect(!harness.facts().terminalCopyMode)
        terminal.isCopyModeActive = true
        #expect(harness.facts().terminalCopyMode, "copy mode did not reach the facts")
        terminal.isCopyModeActive = false
        #expect(!harness.facts().terminalCopyMode)
        #expect(harness.builds == builds)
    }

    /// Chromium's page window is placed, moved or hidden with no focus change (attach, resize, fullscreen,
    /// reparent): the page gets the keys first only while its window is the key window.
    @Test func thePageWindowFollowsItsPlacement() throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let tab = FakePageWindow()
        let builds = harness.seed(KeyRouter.FactSources(chromiumPage: tab))
        #expect(!harness.facts().pageReportsUnhandledKeys, "a page window not placed yet has the keys")
        tab.placed = harness.shell
        #expect(harness.facts().pageReportsUnhandledKeys, "the placed page window does not have the keys")
        tab.placed = nil
        #expect(!harness.facts().pageReportsUnhandledKeys, "a hidden page window still has the keys")
        #expect(harness.builds == builds)
    }

    /// The markdown tab's provider serves a file it cannot save once its config ran: the facts follow the tab
    /// with no rebuild. The config runs first, so no await falls between the reads.
    @Test func aMarkdownFileTurningReadOnlyFollowsItsTab() async throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "key-facts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "transcript.md")
        try Data("# Transcript\n".utf8).write(to: url)
        // A file the host opens read only (a chat transcript): its config says so.
        let file = FilePageProvider(kind: .markdown, file: url, readOnly: true, host: FileHost(), libraries: nil, images: NoImages())
        defer { file.close() }
        _ = try await file.call(FilePageKind.markdown.op("config"), params: .object([:]),
                                context: PageCallContext(page: FilePageKind.markdown.namespace))

        let markdown = try Self.showTopPage(KeyRouter.markdownPageID, in: harness)
        try #require(harness.facts().pageID == KeyRouter.markdownPageID, "the facts did not find the top page's page")
        #expect(!harness.facts().markdownReadOnly)
        let builds = harness.builds
        harness.services.viewers.markdownPages.tabs["key-facts-markdown"] = FilePageService.Tab(page: markdown, provider: file)
        #expect(harness.facts().markdownReadOnly, "a read-only file did not reach the facts")
        harness.services.viewers.markdownPages.tabs["key-facts-markdown"] = nil
        #expect(!harness.facts().markdownReadOnly)
        #expect(harness.builds == builds)
    }

    /// The editor's key sequence is reported by the page and ends by itself after a time. The report runs
    /// first, so no await falls between the reads.
    @Test func theEditorsKeySequenceFollowsItsTab() async throws {
        let harness = try KeyContextCacheTests.harness()
        defer { harness.close() }
        let file = FilePageProvider(kind: .editor, file: nil, host: FileHost(), libraries: nil, images: NoImages())
        defer { file.close() }
        let clock = Uptime()
        file.uptime = { clock.now }
        _ = try await file.call(FilePageKind.editor.op("keySequence"), params: ["pending": true],
                                context: PageCallContext(page: FilePageKind.editor.namespace))
        try #require(file.keySequencePending)

        let editor = CodeEditorKeysTests.page(KeyRouter.codeEditorPageID)
        editor.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        try #require(harness.shell.contentView).addSubview(editor)
        try #require(harness.shell.makeFirstResponder(editor.webView))
        try #require(harness.facts().pageID == KeyRouter.codeEditorPageID, "the facts did not find the editor holding the keys")
        #expect(!harness.facts().pageKeySequencePending)
        let builds = harness.builds
        harness.services.viewers.editorPages.tabs["key-facts-editor"] = FilePageService.Tab(page: editor, provider: file)
        #expect(harness.facts().pageKeySequencePending, "a pending key sequence did not reach the facts")
        clock.now += FilePageProvider.keySequenceLimit
        #expect(!harness.facts().pageKeySequencePending, "an expired key sequence still holds the next key")
        #expect(harness.builds == builds)
    }

    // MARK: Fixtures

    /// Shows a top page whose view is a page web view with `id`, its web view the first responder: the
    /// facts find a top page's page while the responder is in it.
    private static func showTopPage(_ id: String, in harness: KeyContextCacheTests.Harness) throws -> PageWebView {
        let page = CodeEditorKeysTests.page(id)
        let provider = TopPageWithView(InternalPageID(rawValue: "test.key-facts.\(UUID().uuidString)"), view: page)
        harness.services.pages.register(provider)
        let route = TopPageRoute.page(provider.page)
        harness.controller.state.page = route
        try #require(harness.controller.showTopPage(route), "the test page did not show as a top page")
        try #require(harness.controller.shownTopPage == route)
        try #require(harness.shell.makeFirstResponder(page.webView))
        return page
    }

    private final class TopPageWithView: InternalPageProvider {
        let page: InternalPageID
        let title = "Key facts page"
        let symbol = "doc"
        let view: NSView

        init(_ page: InternalPageID, view: NSView) {
            self.page = page
            self.view = view
        }

        func makeView(for key: String, in window: WindowController?) -> NSView { view }
    }

    /// The editor's clock (``FilePageProvider/uptime``), moved by the test.
    private final class Uptime {
        var now: TimeInterval = 100
    }

    private final class FakeSuggestions: KeyFactsSuggestionSource {
        var isShowingSuggestions = false
    }

    private final class FakeCopyMode: KeyFactsCopyModeSource {
        var isCopyModeActive = false
    }

    private final class FakePageWindow: KeyFactsPageWindowSource {
        weak var placed: NSWindow?
        func isPageWindow(_ window: NSWindow) -> Bool { window === placed }
    }

    private final class FileHost: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> JSONValue { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {}
        func opened(_ url: URL) {}
        func openExternal(_ url: URL) {}
        func openFile(_ url: URL) {}
        func openAppLink(_ url: URL) -> Bool { false }
        func isRecent(_ path: String) -> Bool { false }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { false }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_ url: URL, hash: String) {}
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }
}
