import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// Lawrence, 2026-11-24 (video): "when changing tab, chief suddenly lights up?".
///
/// The window's Chromium page (`CefNSWindow`, a child window) takes key while the page has the keyboard; the cmux window
/// stays main. AppKit's glass controls read the window's key appearance, which a key child window turns off, so the
/// Chief header's glass circles and name pill drew grey while a page in the next pane had the keys, and lit up for the
/// ~90 ms the cmux window held the keys between two pages on every tab switch. A window the window kit installs keeps
/// the key look while its own page window holds the keys, and loses it to a panel, another window, another app or no
/// key window, as before. On base this does not compile: the window kit has no page key look.
@MainActor @Suite(.serialized, .closesItsWindows)
struct PageWindowKeyLookTests {
    typealias Keyboard = WindowKeyFamilyTrackerTests.Keyboard

    /// The app window's class: a fresh subclass per test, as the main window (`ShellWindow`) is one of `NSWindow`.
    private static func shellClass() throws -> NSWindow.Type {
        let made: AnyClass = try #require(objc_allocateClassPair(NSWindow.self, "CmuxTestShellWindow_\(UInt32.random(in: 0 ... .max))", 0))
        objc_registerClassPair(made)
        return try #require(made as? NSWindow.Type)
    }

    /// `CefNSWindow`, a Chromium page window's class: the app has it from the Chromium framework, a test process makes
    /// a stand-in of the same name (other suites share it).
    private static func pageClass() throws -> NSWindow.Type {
        if let existing = objc_lookUpClass("CefNSWindow") { return try #require(existing as? NSWindow.Type) }
        let made: AnyClass = try #require(objc_allocateClassPair(NSWindow.self, "CefNSWindow", 0))
        objc_registerClassPair(made)
        return try #require(made as? NSWindow.Type)
    }

    private static func window(_ type: NSWindow.Type) -> NSWindow {
        _ = NSApplication.shared
        let window = type.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
                               backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The window's key look as its controls read it: every getter AppKit's glass reads.
    private static func keyLook(_ window: NSWindow) -> [Bool] {
        PageWindowKeyLook.getters.map { name in
            window.responds(to: NSSelectorFromString(name)) ? (window.value(forKey: name) as? Bool) ?? false : false
        }
    }

    /// An app window as the window kit installs it (`.main`, the cmux window's kind) with `keyboard`'s key tracker, its
    /// page window as a child, and the windows its key look told (`told`).
    private static func shellWithPage(_ keyboard: Keyboard, told: @escaping @MainActor (NSWindow) -> Void = { _ in })
        throws -> (shell: NSWindow, page: NSWindow) {
        let shell = Self.window(try shellClass()), page = Self.window(try pageClass())
        // The keyboard held weakly: a closed window can outlive its test, and AppKit can read its key look after the
        // test's keyboard is gone (an unowned read there ended the test process).
        let environment = WindowKeyEnvironment(center: keyboard.center, keyWindow: { [weak keyboard] in keyboard?.key },
                                               isAppActive: { [weak keyboard] in keyboard?.active ?? false },
                                               nextTurn: { [weak keyboard] check in keyboard?.pending.append(check) },
                                               refresh: told)
        _ = WindowKeyFamily.of(shell, environment: environment)
        shell.install(kind: .main, content: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200)),
                      scope: ThemeScope(level: .room), activeLook: nil)
        shell.addChildWindow(page, ordered: .above)
        keyboard.post([]) // the tracker's first check
        return (shell, page)
    }

    @Test func theWindowKeepsItsKeyLookWhileItsOwnPageHasTheKeys() throws {
        let keyboard = Keyboard()
        let (shell, page) = try Self.shellWithPage(keyboard)
        let devTools = Self.window(try Self.pageClass())
        page.addChildWindow(devTools, ordered: .above)
        defer {
            page.removeChildWindow(devTools); shell.removeChildWindow(page)
            for each in [devTools, page, shell] { each.closeAfterTest() }
        }
        try #require(page.parent === shell, "AppKit did not keep the page window's parent")
        keyboard.key = page
        #expect(Self.keyLook(shell) == [true, true, true], "the window's controls went grey while its own page had the keys")
        keyboard.key = devTools
        #expect(Self.keyLook(shell) == [true, true, true], "the window's controls went grey while its page's DevTools had the keys")
    }

    @Test func aPanelAnotherWindowsPageAnotherAppOrNoKeyWindowStillTakesTheKeyLook() throws {
        let keyboard = Keyboard()
        let (shell, page) = try Self.shellWithPage(keyboard)
        let panel = Self.window(NSPanel.self), other = Self.window(NSWindow.self), othersPage = Self.window(try Self.pageClass())
        shell.addChildWindow(panel, ordered: .above)
        other.addChildWindow(othersPage, ordered: .above)
        defer {
            shell.removeChildWindow(page); shell.removeChildWindow(panel); other.removeChildWindow(othersPage)
            for each in [page, panel, othersPage, other, shell] { each.closeAfterTest() }
        }
        for (key, what) in [(panel, "a panel over the window"), (othersPage, "another window's page"), (other, "another window")] as [(NSWindow, String)] {
            keyboard.key = key
            #expect(Self.keyLook(shell) == [false, false, false], "\(what) holding the keys left the window's key look on")
        }
        keyboard.key = nil
        #expect(Self.keyLook(shell) == [false, false, false], "no key window left the window's key look on")
        (keyboard.key, keyboard.active) = (page, false)
        #expect(Self.keyLook(shell) == [false, false, false], "another app active left the window's key look on")
    }

    /// AppKit redraws a window's controls when that window gains or loses key, not when its own page window takes or
    /// gives up the keys while it is not key: the page taking them from the window at a tab switch, the app coming back
    /// with its page key, a panel taking them from a page, the page closing with no window taking them. The window's
    /// controls are told then, once, and not when AppKit already tells them (the window itself takes the keys) or
    /// when nothing they read changed (the keys moving from one page of it to another).
    @Test func theControlsAreToldWhenTheirPagesTakeOrGiveUpTheKeys() throws {
        let keyboard = Keyboard()
        var told: [NSWindow] = []
        let (shell, page) = try Self.shellWithPage(keyboard) { told.append($0) }
        let panel = Self.window(NSPanel.self), next = Self.window(try Self.pageClass())
        shell.addChildWindow(panel, ordered: .above)
        shell.addChildWindow(next, ordered: .above)
        defer {
            for child in [page, panel, next] { shell.removeChildWindow(child); child.closeAfterTest() }
            shell.closeAfterTest()
        }
        func becomesKey(_ window: NSWindow?) -> [NSWindow] {
            told = []
            keyboard.key = window
            keyboard.post(window == nil ? NSWindow.didResignKeyNotification : NSWindow.didBecomeKeyNotification)
            return told
        }
        #expect(becomesKey(page) == [shell], "the app came back with its page key and the window's controls stayed inactive")
        #expect(becomesKey(shell).isEmpty, "the window took the keys (AppKit tells it) and its controls were told again")
        #expect(becomesKey(next) == [shell], "the next page took the keys from the window and its controls stayed lit up")
        #expect(becomesKey(page).isEmpty, "the keys moved between the window's own pages and its controls were told")
        #expect(becomesKey(panel) == [shell], "a panel took the keys from the page and the window's controls kept the key look")
        _ = becomesKey(page)
        #expect(becomesKey(nil) == [shell], "the page closed with no window taking the keys and the controls kept the key look")
    }
}
