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
