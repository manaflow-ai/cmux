import AppKit
import Testing

@testable import CmuxBrowser

/// Stands in for the class the Chromium runtime defines. The Objective-C
/// name is what `NSClassFromString("CefNSWindow")` finds, as it finds the
/// runtime's class once the framework loads.
@objc(CefNSWindow)
private final class FakeCefNSWindow: NSWindow {}

@MainActor
private enum FakeChromiumRuntime {
    static let pageWindowClass: AnyClass = FakeCefNSWindow.self

    static func makePageWindow() -> NSWindow {
        FakeCefNSWindow(contentRect: .init(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                        backing: .buffered, defer: true)
    }

    static func makeWindow() -> NSWindow {
        NSWindow(contentRect: .init(x: 0, y: 0, width: 80, height: 80), styleMask: [.titled],
                 backing: .buffered, defer: true)
    }
}

@MainActor
@Suite(.serialized) struct ChromiumPageWindowTests {
    init() {
        _ = FakeChromiumRuntime.pageWindowClass
        NSWindow.noteChromiumRuntimeLoaded()
    }

    @Test func pageWindowsAreUnknownUntilTheRuntimeLoads() {
        NSWindow.resetChromiumRuntimeForTesting()
        let main = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        #expect(!page.isChromiumPageWindow)
        #expect(page.chromiumActingWindow(fallback: main) === page)
    }

    @Test func ordinaryWindowsActForThemselves() {
        defer { NSWindow.resetChromiumRuntimeForTesting() }
        let window = FakeChromiumRuntime.makeWindow()
        let other = FakeChromiumRuntime.makeWindow()
        #expect(!window.isChromiumPageWindow)
        #expect(window.chromiumActingWindow(fallback: other) === window)
    }

    @Test func placedPageWindowActsForTheTopOfItsParentChain() {
        defer { NSWindow.resetChromiumRuntimeForTesting() }
        let main = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        #expect(page.isChromiumPageWindow)
        main.addChildWindow(page, ordered: .above)
        defer { main.removeChildWindow(page) }
        #expect(page.chromiumActingWindow(fallback: nil) === main)
    }

    @Test func parentlessPageWindowActsForTheFallback() {
        defer { NSWindow.resetChromiumRuntimeForTesting() }
        let main = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        let otherPage = FakeChromiumRuntime.makePageWindow()
        #expect(page.chromiumActingWindow(fallback: main) === main)
        #expect(page.chromiumActingWindow(fallback: nil) == nil)
        #expect(page.chromiumActingWindow(fallback: otherPage) == nil)
    }
}

@MainActor
@Suite(.serialized) struct ChromiumChromeClickKeyWindowTests {
    init() {
        _ = FakeChromiumRuntime.pageWindowClass
        NSWindow.noteChromiumRuntimeLoaded()
    }

    @Test func classifiesTheKeyWindowForAPressIntoACmuxWindow() {
        defer { NSWindow.resetChromiumRuntimeForTesting() }
        let main = FakeChromiumRuntime.makeWindow()
        let otherMain = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        let otherPage = FakeChromiumRuntime.makePageWindow()
        main.addChildWindow(page, ordered: .above)
        otherMain.addChildWindow(otherPage, ordered: .above)
        defer {
            main.removeChildWindow(page)
            otherMain.removeChildWindow(otherPage)
        }
        typealias KeyWindow = ChromiumChromeClickFacts.KeyWindow
        #expect(KeyWindow(keyWindow: page, for: main, fallback: nil) == .ownChromiumPage)
        #expect(KeyWindow(keyWindow: otherPage, for: main, fallback: nil) == .other)
        #expect(KeyWindow(keyWindow: otherMain, for: main, fallback: nil) == .other)
        #expect(KeyWindow(keyWindow: nil, for: main, fallback: nil) == .noKeyWindow)
        #expect(KeyWindow(keyWindow: main, for: main, fallback: nil) == .other)
        let parentless = FakeChromiumRuntime.makePageWindow()
        #expect(KeyWindow(keyWindow: parentless, for: main, fallback: main) == .ownChromiumPage)
        #expect(KeyWindow(keyWindow: parentless, for: main, fallback: otherMain) == .other)
    }
}
