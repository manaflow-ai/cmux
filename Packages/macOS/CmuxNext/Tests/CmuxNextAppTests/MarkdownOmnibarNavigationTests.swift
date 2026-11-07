import CmuxNextFiles
@testable import CmuxNextApp
import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Markdown tab's omnibar is the browser's row with Back, Forward and Reload
/// (plans/cmux-next/markdown-omnibar-DESIGN.md section 2b): the page's history message reaches the
/// host, the buttons follow it, and each button runs its action on the tab.
@MainActor @Suite struct MarkdownOmnibarNavigationTests {
    private final class Host: FilePageHosting {
        var history: [(canBack: Bool, canForward: Bool)] = []
        var showsOmnibar: Bool { true }
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
        func historyChanged(canBack: Bool, canForward: Bool) { history.append((canBack, canForward)) }
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }

    @Test func thePagesHistoryMessageReachesTheHost() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "md-nav-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "a.md")
        try Data("# A\n".utf8).write(to: url)
        let host = Host()
        let provider = FilePageProvider(kind: .markdown, file: url, host: host, libraries: nil, images: NoImages())
        defer { provider.close() }
        let context = PageCallContext(page: FilePageKind.markdown.namespace)
        _ = try await provider.call("cmux.markdown.history", params: ["canBack": true, "canForward": false], context: context)
        _ = try await provider.call("cmux.markdown.history", params: ["canBack": false, "canForward": true], context: context)
        #expect(host.history.map(\.canBack) == [true, false])
        #expect(host.history.map(\.canForward) == [false, true])
    }

    @Test func theButtonsFollowTheHistoryAndRunTheTabsActions() {
        var ran: [String] = []
        let actions = MarkdownOmnibarActions(
            open: { _, _ in }, returnFocus: {}, liveLink: { _ in nil }, openInBrowser: { _ in },
            back: { ran.append("back") }, forward: { ran.append("forward") }, reload: { ran.append("reload") })
        let bar = MarkdownOmnibarBar(suggestionEngine: OmniboxSuggestionEngine(), actions: actions)
        // The page draws Back, Forward and Reload; a press arrives as the page's command and runs
        // only while its button is enabled.
        let row = bar.toolbar.addressBar
        func press() {
            row.handle(.goBack)
            row.handle(.goForward)
            row.handle(.reload)
        }

        // The empty state: nothing to go back to, nothing to reload.
        #expect(!row.navigation.canGoBack && !row.navigation.canGoForward)
        press()
        #expect(ran.isEmpty)

        bar.show(URL(fileURLWithPath: "/tmp/a.md"))
        #expect(!row.navigation.canGoBack && !row.navigation.canGoForward)
        press()
        #expect(ran == ["reload"])
        ran.removeAll()

        bar.setHistory(canBack: true, canForward: false)
        #expect(row.navigation.canGoBack && !row.navigation.canGoForward)
        bar.setHistory(canBack: false, canForward: true)
        #expect(!row.navigation.canGoBack && row.navigation.canGoForward)

        bar.setHistory(canBack: true, canForward: true)
        press()
        #expect(ran == ["back", "forward", "reload"])
    }

    @Test func theRowIsTheBrowserToolbarsHeight() {
        let bar = MarkdownOmnibarBar(suggestionEngine: OmniboxSuggestionEngine(), actions: MarkdownOmnibarActions(
            open: { _, _ in }, returnFocus: {}, liveLink: { _ in nil }, openInBrowser: { _ in },
            back: {}, forward: {}, reload: {}))
        #expect(bar.toolbar.preferredHeight == ToolbarRowMetrics.toolbarHeight(scale: NSScreen.main?.backingScaleFactor ?? 2))
        // The row sizes the bar (its intrinsic height), so a density change resizes the Markdown tab's row too.
        #expect(bar.fittingSize.height == bar.toolbar.preferredHeight)
    }

    /// The settings rows and the omnibar clamp `browser.omnibar.height` and `fontSize` to the same ranges.
    @Test func theOmnibarSizeRangesMatchTheSettingsRows() {
        #expect(BrowserOmnibarSetting.heightRange == OmnibarMetrics.heightRange)
        #expect(BrowserOmnibarSetting.fontSizeRange == OmnibarMetrics.fontSizeRange)
    }
}
