import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A Chromium page draws in its own child window over the cmux window, so a launch picture (a view
/// in the pane) is under it from the page's commit, when Chromium fills the page with its base color: while the
/// picture shows, the page window keeps a hole over all of the page (`BrowserPageCovering`). And a Chromium page
/// holds the keyboard as a key child window, not through the cmux window's first responder, which is how a page
/// with a focused password field is found (`holdsKeyboard(in:keyWindow:)`).
@MainActor @Suite(.serialized) struct BrowserPageCoveringTests {
    /// A shown Chromium page past its first real page has no hole of its own; covered, all of it is one, and the
    /// fork's tracker reads that hole; uncovered, the page shows again.
    @Test func aCoveredChromiumPageIsAHoleOverAllOfThePage() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.container.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        host.add(tab)
        host.present(tab, in: tab.container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        tab.reachedFirstRealPage(settled: true)
        try #require(tab.pageWindowHoles.isEmpty, "a shown real page has no hole")

        tab.isPageCovered = true
        #expect(tab.pageWindowHoles == [host.hostView.frame], "the page window draws over the picture")
        let read = host.hostView.cmuxOcclusionRects().compactMap { ($0 as? NSValue)?.rectValue }
        #expect(read == [host.hostView.bounds], "the fork's tracker does not read the hole")

        tab.isPageCovered = false
        #expect(tab.pageWindowHoles.isEmpty, "the page stayed hidden after the picture went")
    }

    @Test func aChromiumPageHoldsTheKeyboardAsTheKeyChildWindow() {
        let window = Self.window(), pageWindow = Self.window()
        defer { window.close(); pageWindow.close() }
        window.addChildWindow(pageWindow, ordered: .above)
        let chromium = Self.page(.childWindow), webKit = Self.page(.inView)
        window.contentView?.addSubview(chromium.contentView)
        window.contentView?.addSubview(webKit.contentView)
        #expect(chromium.holdsKeyboard(in: window, keyWindow: pageWindow), "a Chromium page's password field went unseen")
        #expect(!chromium.holdsKeyboard(in: window, keyWindow: window))
        #expect(!chromium.holdsKeyboard(in: window, keyWindow: nil))
        #expect(!webKit.holdsKeyboard(in: window, keyWindow: pageWindow), "a page in a view held a child window's keys")
    }

    @Test func aPageInAViewHoldsTheKeyboardThroughTheFirstResponder() {
        let window = Self.window()
        defer { window.close() }
        let page = Self.page(.inView), field = KeyView(), outside = KeyView()
        page.contentView.addSubview(field)
        window.contentView?.addSubview(page.contentView)
        window.contentView?.addSubview(outside)
        #expect(window.makeFirstResponder(field))
        #expect(page.holdsKeyboard(in: window, keyWindow: window))
        #expect(window.makeFirstResponder(outside))
        #expect(!page.holdsKeyboard(in: window, keyWindow: window), "a view outside the page held its keyboard")
    }

    // MARK: Fixtures

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func page(_ presentation: BrowserPresentation) -> MockBrowserTab {
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        page.presentation = presentation
        return page
    }

    /// A runtime that outlives the test (a shown tab schedules work that reads its runtime after the test returned)
    /// on a shim whose window creates start and whose other functions do nothing.
    private static func runtime() throws -> (CEFRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-page-covering-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CoveringShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }
}

/// A view that takes the keyboard (a page's focused field).
private final class KeyView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Stand-in shim:`cmux_shim_create_window` reports the window started; every other function does nothing and
/// returns 0.
private nonisolated enum CoveringShim {
    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
