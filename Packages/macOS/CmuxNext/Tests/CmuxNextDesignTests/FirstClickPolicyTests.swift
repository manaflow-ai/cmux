import AppKit
@testable import CmuxNextDesign
import Testing

/// One press acts while cmux's own page, panel or no window holds the key (user 2026-10-30: "a lot
/// of buttons, i feel like i have to click twice for it to actually work"); a press in a window
/// behind another app or another cmux main window, or under a sheet or a modal session, keeps
/// AppKit's activate-only first click.
@MainActor
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
        defer { window.removeChildWindow(page) }
        #expect(press(window, type: type, key: page))
    }

    @Test func aPressActsWhileAPageInsideAChildPanelHoldsTheKey() {
        let window = mainWindow()
        let host = panel()
        window.addChildWindow(host, ordered: .above)
        let page = pageWindow(of: host)
        defer { host.removeChildWindow(page); window.removeChildWindow(host) }
        #expect(press(window, key: page))
    }

    @Test func aPressActsWhileAFreePanelOrNoWindowHoldsTheKey() {
        let window = mainWindow()
        #expect(press(window, key: panel()))
        #expect(press(window, key: nil))
        #expect(press(window, key: nil, main: .some(nil)))
    }

    @Test func aPressInAWindowBehindAnotherAppOnlyBringsItForward() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { window.removeChildWindow(page) }
        #expect(!press(window, key: page, active: false))
        #expect(!press(window, key: nil, active: false))
    }

    @Test func aPressInAWindowBehindAnotherMainWindowOnlyBringsItForward() {
        let window = mainWindow(), other = mainWindow()
        #expect(!press(window, key: other, main: other))
        // That window's own page or panel holds the key: still the other window's.
        let otherPage = pageWindow(of: other)
        let otherPanel = panel()
        other.addChildWindow(otherPanel, ordered: .above)
        defer { other.removeChildWindow(otherPage); other.removeChildWindow(otherPanel) }
        #expect(!press(window, key: otherPage, main: other))
        #expect(!press(window, key: otherPanel, main: other))
        // A free panel or no window holds the key, but the other window is the main one: it stays in front.
        #expect(!press(window, key: panel(), main: other))
        #expect(!press(window, key: nil, main: other))
    }

    @Test func aSheetOrAModalSessionKeepsTheKeys() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { window.removeChildWindow(page) }
        #expect(!press(window, key: page, modal: true))
        #expect(!press(window, key: nil, modal: true))
    }

    @Test func anAttachedSheetKeepsTheKeys() throws {
        let window = mainWindow()
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let sheet = panel()
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }
        try #require(window.attachedSheet === sheet)
        let page = pageWindow(of: window)
        defer { window.removeChildWindow(page) }
        #expect(!press(window, key: page))
        #expect(!press(window, key: sheet))
        #expect(!press(window, key: nil))
    }

    @Test func aCommandPressActsOverTheWindowsOwnPageOnly() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { window.removeChildWindow(page) }
        #expect(press(window, key: page, modifiers: .command))
        #expect(!press(window, key: panel(), modifiers: .command))
        #expect(!press(window, key: nil, modifiers: .command))
    }

    @Test func otherEventsKeepAppKitsRule() {
        let window = mainWindow()
        let page = pageWindow(of: window)
        defer { window.removeChildWindow(page) }
        for type in [NSEvent.EventType.leftMouseUp, .mouseMoved, .keyDown, .scrollWheel] {
            #expect(!press(window, type: type, key: page), "\(type.rawValue)")
        }
    }

    @Test func aWindowThatCannotBecomeKeyKeepsAppKitsRule() {
        let borderless = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!press(borderless, key: nil))
    }
}
