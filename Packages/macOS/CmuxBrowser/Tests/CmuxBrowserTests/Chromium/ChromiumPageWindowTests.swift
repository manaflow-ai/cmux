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

/// The mouse buttons a test holds.
@MainActor
private final class HeldButtons {
    var mask = 1
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

    /// A tab dragged from the pane's tab bar over a Chromium pane must reach
    /// the pane's drop targets: while the press that began in the cmux window
    /// is held, its page windows ignore the mouse; after release they take it again.
    @Test func aPressInTheCmuxWindowLetsDragsPassThroughItsPagesUntilRelease() {
        defer { NSWindow.resetChromiumRuntimeForTesting() }
        let main = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        let other = FakeChromiumRuntime.makeWindow()
        main.addChildWindow(page, ordered: .above)
        main.addChildWindow(other, ordered: .above)
        defer {
            main.removeChildWindow(page)
            main.removeChildWindow(other)
        }
        let buttons = HeldButtons()
        let gate = ChromiumPagePressGate(pressedMouseButtons: { buttons.mask })

        gate.pressBegan(in: main)
        #expect(page.ignoresMouseEvents)
        #expect(!other.ignoresMouseEvents)

        gate.windowDidUpdate()
        #expect(page.ignoresMouseEvents)

        buttons.mask = 0
        gate.windowDidUpdate()
        #expect(!page.ignoresMouseEvents)
        #expect(!gate.isHolding)
    }

    /// A page window something else set to ignore the mouse keeps ignoring it.
    @Test func thePressGateRestoresOnlyThePagesItChanged() {
        defer { NSWindow.resetChromiumRuntimeForTesting() }
        let main = FakeChromiumRuntime.makeWindow()
        let page = FakeChromiumRuntime.makePageWindow()
        page.ignoresMouseEvents = true
        main.addChildWindow(page, ordered: .above)
        defer { main.removeChildWindow(page) }
        let gate = ChromiumPagePressGate(pressedMouseButtons: { 0 })

        gate.pressBegan(in: main)
        #expect(!gate.isHolding)
        gate.release()
        #expect(page.ignoresMouseEvents)
    }

    /// A held press whose window went away (closed before its release was
    /// seen) must not strand the gate: a press in another window releases
    /// the first window's pages and holds, then releases, its own.
    @Test func aPressInAnotherWindowReleasesTheFirstAndIsReleasedItself() {
        defer { NSWindow.resetChromiumRuntimeForTesting() }
        let second = FakeChromiumRuntime.makeWindow()
        let secondPage = FakeChromiumRuntime.makePageWindow()
        second.addChildWindow(secondPage, ordered: .above)
        defer { second.removeChildWindow(secondPage) }
        let buttons = HeldButtons()
        let gate = ChromiumPagePressGate(pressedMouseButtons: { buttons.mask })

        // The first window closes while its press is held.
        autoreleasepool {
            let first = FakeChromiumRuntime.makeWindow()
            let firstPage = FakeChromiumRuntime.makePageWindow()
            first.addChildWindow(firstPage, ordered: .above)
            gate.pressBegan(in: first)
            first.removeChildWindow(firstPage)
        }
        gate.pressBegan(in: second)
        #expect(secondPage.ignoresMouseEvents)

        buttons.mask = 0
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: second)
        #expect(!secondPage.ignoresMouseEvents)
        #expect(!gate.isHolding)
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
