import AppKit
@testable import CmuxNextBrowser
import ObjectiveC
import Testing

/// cef-ordered-windows, 2026-11-06: each Cmd-N with 60 workspaces held the main thread 8-45 ms
/// in `-[NSApp orderedWindows]`, a synchronous WindowServer query that waits until the
/// WindowServer has applied cmux's pending Core Animation transaction. Chromium's
/// `WebContentsOcclusionCheckerMac` makes that query on the next run-loop pass after any order
/// change of a window with no parent window that holds a web contents view. The fork's tracker
/// orders the page window out with no parent window (`-hideNow`, `-setDetached:YES`), so every
/// hidden or detached page scheduled a check. An embedded page window (`CefNSWindow`
/// `-isEmbeddedInParentView`) now says it holds no web contents view to the checker: its parent
/// view decides whether the page shows. The stand-in class carries Chromium's category method
/// (`-[NSWindow containsWebContentsViewCocoa]`) and the fork's embedded flag.
@MainActor @Suite struct ChromiumPageWindowOcclusionTests {
    class StandInPageWindow: NSWindow {
        var embedded = true
        @objc dynamic func containsWebContentsViewCocoa() -> Bool { true }
        @objc dynamic func isEmbeddedInParentView() -> Bool { embedded }
    }

    private static func pageWindowClass() throws -> StandInPageWindow.Type {
        let name = "CmuxTestOcclusionCefNSWindow_\(UInt32.random(in: 0 ... .max))"
        let cls = try #require(objc_allocateClassPair(StandInPageWindow.self, name, 0))
        objc_registerClassPair(cls)
        return try #require(cls as? StandInPageWindow.Type)
    }

    /// Through `NSWindow.Type`: a Swift subclass with stored properties has no
    /// required initializer, and the Objective-C one still makes `type`'s instance.
    private static func window(of type: StandInPageWindow.Type) throws -> StandInPageWindow {
        let windowType: NSWindow.Type = type
        let window = try #require(windowType.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                                                  styleMask: [.titled], backing: .buffered, defer: true) as? StandInPageWindow)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func anEmbeddedPageWindowIsNoBrowserWindowForTheOcclusionChecker() throws {
        let cls = try Self.pageWindowClass()
        let page = try Self.window(of: cls)
        #expect(page.containsWebContentsViewCocoa())
        #expect(ChromiumPageWindowMain.installPageRules(on: cls))
        #expect(!page.containsWebContentsViewCocoa())
        #expect(try !Self.window(of: cls).containsWebContentsViewCocoa())
    }

    @Test func aPageWindowThatIsNotEmbeddedKeepsChromiumsAnswer() throws {
        let cls = try Self.pageWindowClass()
        ChromiumPageWindowMain.installPageRules(on: cls)
        let page = try Self.window(of: cls)
        page.embedded = false
        #expect(page.containsWebContentsViewCocoa())
        page.embedded = true
        #expect(!page.containsWebContentsViewCocoa())
    }

    @Test func otherWindowsKeepTheirAnswer() throws {
        ChromiumPageWindowMain.installPageRules(on: try Self.pageWindowClass())
        #expect(try Self.window(of: StandInPageWindow.self).containsWebContentsViewCocoa())
    }

    @Test func installingAgainIsHarmless() throws {
        let cls = try Self.pageWindowClass()
        #expect(ChromiumPageWindowMain.installPageRules(on: cls))
        #expect(ChromiumPageWindowMain.installPageRules(on: cls))
        let page = try Self.window(of: cls)
        #expect(!page.containsWebContentsViewCocoa())
        page.embedded = false
        #expect(page.containsWebContentsViewCocoa())
    }
}
