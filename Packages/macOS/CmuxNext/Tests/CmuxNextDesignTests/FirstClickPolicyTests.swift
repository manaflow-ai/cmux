import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// One press acts while cmux's own page, panel or no window holds the key (user 2026-10-30: "a lot
/// of buttons, i feel like i have to click twice for it to actually work"); a press in a window
/// behind another app or another cmux main window, or under a sheet or a modal session, keeps
/// AppKit's activate-only first click.
@MainActor @Suite(.closesItsWindows)
struct FirstClickPolicyTests {
    private let policy = FirstClickPolicy()

    private func mainWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    }

    /// A Chromium page window: a plain child window of the main window.
    private func pageWindow(of parent: NSWindow) -> NSWindow {
        let page = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        parent.addChildWindow(page, ordered: .above)
        return page
    }

    private func panel() -> NSPanel {
        NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    private func close(_ windows: NSWindow...) {
        for window in windows { window.closeAfterTest() }
    }

    /// `main` defaults to `window`: the press is in the app's main window.
    private func press(_ window: NSWindow, type: NSEvent.EventType = .leftMouseDown, key: NSWindow?, main: NSWindow?? = .none,
                       active: Bool = true, modal: Bool = false, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        policy.takesFirstClick(type: type, modifiers: modifiers, in: window, keyWindow: key, mainWindow: main ?? window,
                               appIsActive: active, appIsModal: modal)
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func aPressActsWhileTheWindowsOwnPageHoldsTheKey(type: NSEvent.EventType) {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { close(page, window) }
        defer { window.removeChildWindow(page) }
        #expect(press(window, type: type, key: page))
    }

    @Test func aPressActsWhileAPageInsideAChildPanelHoldsTheKey() {
        let window = mainWindow()
        let host = panel()
        window.addChildWindow(host, ordered: .above)
        let page = pageWindow(of: host)
        defer { close(page, host, window) }
        defer { host.removeChildWindow(page); window.removeChildWindow(host) }
        #expect(press(window, key: page))
    }

    @Test func aPressActsWhileAFreePanelOrNoWindowHoldsTheKey() {
        let window = mainWindow()
        let free = panel()
        defer { close(free, window) }
        #expect(press(window, key: free))
        #expect(press(window, key: nil))
        #expect(press(window, key: nil, main: .some(nil)))
    }

    @Test func aPressInAWindowBehindAnotherAppOnlyBringsItForward() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { close(page, window) }
        defer { window.removeChildWindow(page) }
        #expect(!press(window, key: page, active: false))
        #expect(!press(window, key: nil, active: false))
    }

    @Test func aPressInAWindowBehindAnotherMainWindowOnlyBringsItForward() {
        let window = mainWindow(), other = mainWindow()
        let freePanel = panel()
        defer { close(freePanel, other, window) }
        #expect(!press(window, key: other, main: other))
        // That window's own page or panel holds the key: still the other window's.
        let otherPage = pageWindow(of: other)
        let otherPanel = panel()
        other.addChildWindow(otherPanel, ordered: .above)
        defer { close(otherPage, otherPanel) }
        defer { other.removeChildWindow(otherPage); other.removeChildWindow(otherPanel) }
        #expect(!press(window, key: otherPage, main: other))
        #expect(!press(window, key: otherPanel, main: other))
        // A free panel or no window holds the key, but the other window is the main one: it stays in front.
        #expect(!press(window, key: freePanel, main: other))
        #expect(!press(window, key: nil, main: other))
    }

    @Test func aSheetOrAModalSessionKeepsTheKeys() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { close(page, window) }
        defer { window.removeChildWindow(page) }
        #expect(!press(window, key: page, modal: true))
        #expect(!press(window, key: nil, modal: true))
    }

    /// The rule under a sheet, asked with the two values the policy reads (`attachedSheet` of the pressed window,
    /// `sheetParent` of the key window) set by the test, so it runs the same on each host: a worker with no window
    /// session attaches no real sheet (`anAttachedSheetKeepsTheKeys`).
    @Test func aWindowUnderASheetKeepsTheKeys() {
        let window = SheetedWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable],
                                   backing: .buffered, defer: true)
        let sheet = SheetPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                               defer: true)
        let page = pageWindow(of: window)
        defer { close(page, sheet, window) }
        defer { window.removeChildWindow(page) }
        // With no sheet the same press acts, so each `false` below comes from the sheet and not from these windows.
        #expect(press(window, key: page))
        (window.stubbedSheet, sheet.stubbedParent) = (sheet, window)
        defer { (window.stubbedSheet, sheet.stubbedParent) = (nil, nil) }
        #expect(!press(window, key: page))
        #expect(!press(window, key: sheet))
        #expect(!press(window, key: nil))
    }

    /// The `keyWindow.sheetParent` clause alone: the key window reports that it is the sheet of another window, one
    /// that is not the pressed window or the main one. The test sets `sheetParent`; it begins no real sheet, so it
    /// does not show which windows AppKit puts in this state. A press in this window does not take the keys.
    @Test func aSheetOnAnotherWindowKeepsTheKeys() {
        let window = mainWindow()
        let owner = panel()
        let sheet = SheetPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                               defer: true)
        defer { close(sheet, owner, window) }
        // The same panel as no window's sheet is a free panel: one press acts.
        #expect(press(window, key: sheet))
        sheet.stubbedParent = owner
        defer { sheet.stubbedParent = nil }
        #expect(!press(window, key: sheet))
        #expect(!press(window, key: sheet, main: .some(nil)))
    }

    /// The rule with a real AppKit sheet: it is the one test that fails if a macOS stops setting `attachedSheet`,
    /// the value the policy reads. It needs a window session. On a worker with none (no screen, the window gets no
    /// window number) `beginSheet` shows the sheet and sets its `sheetParent` but leaves the window's
    /// `attachedSheet` nil, so the `#require` below fails before the policy is asked. There it is skipped, and a
    /// skip is no pass; `aWindowUnderASheetKeepsTheKeys` asks the rule on each host.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "needs a window session: with no screen AppKit attaches no sheet"))
    func anAttachedSheetKeepsTheKeys() throws {
        let window = mainWindow()
        window.orderFront(nil)
        let sheet = panel()
        defer { close(sheet, window) }
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }
        try #require(window.attachedSheet === sheet)
        let page = pageWindow(of: window)
        defer { close(page) }
        defer { window.removeChildWindow(page) }
        #expect(!press(window, key: page))
        #expect(!press(window, key: sheet))
        #expect(!press(window, key: nil))
    }

    @Test func aCommandPressActsOverTheWindowsOwnPageOnly() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        let free = panel()
        defer { close(page, free, window) }
        defer { window.removeChildWindow(page) }
        #expect(press(window, key: page, modifiers: .command))
        #expect(!press(window, key: free, modifiers: .command))
        #expect(!press(window, key: nil, modifiers: .command))
    }

    @Test func otherEventsKeepAppKitsRule() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { close(page, window) }
        defer { window.removeChildWindow(page) }
        for type in [NSEvent.EventType.leftMouseUp, .mouseMoved, .keyDown, .scrollWheel] {
            #expect(!press(window, type: type, key: page), "\(type.rawValue)")
        }
    }

    @Test func aWindowThatCannotBecomeKeyKeepsAppKitsRule() {
        let borderless = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        defer { close(borderless) }
        #expect(!press(borderless, key: nil))
    }
}

/// A window whose `attachedSheet` the test sets: what AppKit reports while a sheet is on the window.
private final class SheetedWindow: NSWindow {
    var stubbedSheet: NSWindow?

    override var attachedSheet: NSWindow? { stubbedSheet }
}

/// A panel whose `sheetParent` the test sets: what AppKit reports for a sheet on that window.
private final class SheetPanel: NSPanel {
    weak var stubbedParent: NSWindow?

    override var sheetParent: NSWindow? { stubbedParent }
}
