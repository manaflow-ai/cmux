import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextFocusUI
import Foundation
import Testing

/// Lawrence, 2026-11-15 ("the first Cmd+F press misses", fresh-launch run 5 of 20): a relaunched window restores a
/// Markdown tab, a cmux page in a Chromium page window. The focus applier clears the cmux window's responder for the
/// page window, but the page's grant waits for its first frame out of the window, 40-100 ms. Cmd-F opened the page's
/// find field, and the letters typed after it went to the cmux window, which had no responder: they reached no view.
/// A browser tab's page was already awaited until its grant (``AwaitedContent/Pane/shownPageReady``); a cmux page's or
/// an agent chat's page window was not. Now each is awaited, so the window's key hold keeps the keys and sends them
/// to the page window once it has the keys.
@MainActor @Suite(.serialized) struct ChildPageKeyHoldTests {
    private static var runtimes: [CEFRuntime] = []

    private static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }

    /// A created Chromium tab with a loaded document and no focus ask: ready for keys.
    private static func loadedTab() throws -> (CEFTab, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "child-page-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try library(), storage: CEFProfileStorage(root: root))
        runtimes.append(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.add(tab)
        host.ensureCreated(tab)
        runtime.handle(.afterCreated(browser: 7, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        tab.hasDocument = true
        return (tab, root)
    }

    /// The shown content's page window waits for its focus grant: a key typed now would reach no view, so the content
    /// is not ready. That holds for a browser tab's page and for a cmux page's or an agent chat's page window alike.
    @Test func aShownPageWindowWaitingForItsGrantIsNotReadyForKeys() throws {
        let (tab, root) = try Self.loadedTab()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(tab.pageReady, "a loaded page with no focus ask is ready: the test proves nothing")
        #expect(AwaitedContent.Pane.pageReady(browser: nil, pageWindow: tab.pageReady), "a ready page window counts as not ready")

        tab.keepFocusAsk()  // the grant waits for the page's first frame out of the window
        #expect(!AwaitedContent.Pane.pageReady(browser: tab.pageReady, pageWindow: tab.pageReady), "a browser tab waiting for its grant counts as ready")
        #expect(!AwaitedContent.Pane.pageReady(browser: nil, pageWindow: tab.pageReady),
                "a cmux page (Markdown) or an agent chat whose page window waits for its grant counts as ready: the keys typed now reach no view")

        tab.dropFocusAsk()
        #expect(AwaitedContent.Pane.pageReady(browser: nil, pageWindow: tab.pageReady))
        #expect(AwaitedContent.Pane.pageReady(browser: nil, pageWindow: nil), "content with no Chromium page (a native page) is ready")
    }
}
