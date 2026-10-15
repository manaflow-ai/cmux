import AppKit
import ObjectiveC
import Testing

@testable import CmuxBrowser

/// Registers a stand-in `CefNSWindow` (the class the Chromium runtime defines)
/// once per test process, as the framework would when it loads.
@MainActor
private enum FakeChromiumRuntime {
    static let pageWindowClass: AnyClass = {
        if let existing = NSClassFromString("CefNSWindow") { return existing }
        guard let pair = objc_allocateClassPair(NSWindow.self, "CefNSWindow", 0) else {
            fatalError("could not allocate CefNSWindow")
        }
        objc_registerClassPair(pair)
        return pair
    }()

    /// A window whose class is the stand-in (it adds no state, so swapping
    /// the class of a plain window is what the runtime's subclass looks like).
    static func makePageWindow() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        object_setClass(window, pageWindowClass)
        return window
    }

    static func makeWindow() -> NSWindow {
        NSWindow(contentRect: .init(x: 0, y: 0, width: 80, height: 80), styleMask: [.titled],
                 backing: .buffered, defer: true)
    }
}

@MainActor
@Suite(.serialized) struct ChromiumPageWindowTests {
    @Test func ordinaryWindowsActForThemselves() {
        let window = FakeChromiumRuntime.makeWindow()
        let other = FakeChromiumRuntime.makeWindow()
        #expect(!ChromiumPageWindow.isPageWindow(window))
        #expect(ChromiumPageWindow.actingWindow(for: window, fallback: other) === window)
        #expect(ChromiumPageWindow.actingWindow(for: nil, fallback: other) == nil)
    }

    @Test func placedPageWindowActsForTheTopOfItsParentChain() {
        let main = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        #expect(ChromiumPageWindow.isPageWindow(page))
        main.addChildWindow(page, ordered: .above)
        defer { main.removeChildWindow(page) }
        #expect(ChromiumPageWindow.actingWindow(for: page, fallback: nil) === main)
    }

    @Test func parentlessPageWindowActsForTheFallback() {
        let main = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        let otherPage = FakeChromiumRuntime.makePageWindow()
        #expect(ChromiumPageWindow.actingWindow(for: page, fallback: main) === main)
        #expect(ChromiumPageWindow.actingWindow(for: page, fallback: nil) == nil)
        #expect(ChromiumPageWindow.actingWindow(for: page, fallback: otherPage) == nil)
    }
}
