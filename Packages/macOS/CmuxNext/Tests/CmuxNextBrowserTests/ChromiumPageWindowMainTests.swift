import AppKit
@testable import CmuxNextBrowser
import ObjectiveC
import Testing

/// Leo, 2026-10-21: moving into a browser-tab workspace must not make cmux's own window look
/// inactive. AppKit makes a key window main too when it can be main, so Chromium's page window
/// (`CefNSWindow`, a child of the cmux window that takes key for the keyboard) took main from the
/// cmux window, which then drew grey traffic lights and grey glass. Page windows now say no to
/// main and still take key. The stand-in class is a fresh subclass of a window that may be main,
/// as `CefNSWindow` may be in the app (a test host with no window server says no for a plain one).
@MainActor @Suite struct ChromiumPageWindowMainTests {
    class MainCapableWindow: NSWindow {
        override var canBecomeMain: Bool { true }
    }

    private static func pageWindowClass() throws -> NSWindow.Type {
        let name = "CmuxTestCefNSWindow_\(UInt32.random(in: 0 ... .max))"
        let cls = try #require(objc_allocateClassPair(MainCapableWindow.self, name, 0))
        objc_registerClassPair(cls)
        return try #require(cls as? NSWindow.Type)
    }

    private static func window(of type: NSWindow.Type) -> NSWindow {
        let window = type.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aPageWindowTakesKeyButNeverMain() throws {
        let cls = try Self.pageWindowClass()
        let page = Self.window(of: cls)
        #expect(page.canBecomeMain)
        let canBeKey = page.canBecomeKey
        #expect(ChromiumPageWindowMain.keepOutOfMain(cls))
        #expect(!page.canBecomeMain)
        #expect(!Self.window(of: cls).canBecomeMain)
        #expect(page.canBecomeKey == canBeKey)
    }

    @Test func otherWindowsKeepTheirMainRule() throws {
        ChromiumPageWindowMain.keepOutOfMain(try Self.pageWindowClass())
        #expect(Self.window(of: MainCapableWindow.self).canBecomeMain)
    }

    @Test func installingAgainIsHarmless() throws {
        let cls = try Self.pageWindowClass()
        #expect(ChromiumPageWindowMain.keepOutOfMain(cls))
        #expect(ChromiumPageWindowMain.keepOutOfMain(cls))
        #expect(!Self.window(of: cls).canBecomeMain)
    }
}
