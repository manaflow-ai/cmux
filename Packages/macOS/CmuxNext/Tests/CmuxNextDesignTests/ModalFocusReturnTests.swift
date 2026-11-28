import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// When a dialog leaves, the keyboard goes back where it was, unless the person moved it to another window meanwhile
/// (``WindowOverlayHost/focusMoved``). Before, any other window that became key while the dialog showed counted as
/// such a move for good (a127's findings on cmux#45851, 2026-11-17):
///
/// - a window that took the keyboard and was gone again when the dialog left (a popover, a sheet, Settings closed)
///   left the keyboard in no window;
/// - a page window of the dialog's own window (a Chromium page that takes key when it shows or wakes, under a question
///   that covers the whole window, where the person cannot click it) counted as another window too.
@MainActor @Suite(.closesItsWindows) struct ModalFocusReturnTests {
    private static let spec = CmuxDialogSpec(
        title: "Close \u{201C}Align GUI Bullet Points\u{201D}?", lines: ["Still running: claude."],
        buttons: [.cancel("Cancel"), CmuxDialogButton(id: "confirm", title: "Close", role: .destructive)],
        identifier: "cmux.dialog.confirmation")

    private struct Shown {
        let center: CmuxDialogCenter
        let window: NSWindow
        let id: Int
        let host: WindowOverlayHost

        func close() {
            center.dismiss(id)
            for child in window.childWindows ?? [] where child !== host.panel { child.close() }
            window.close()
        }
    }

    private static func show() throws -> Shown {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: {}, isAppActive: { true }))
        let id = center.present(spec, in: .window(window), completion: { _ in })
        let host = try #require(WindowOverlayHost.existingHost(for: window))
        try #require(host.handles.contains { $0.options.isModal }, "the question is modal")
        return Shown(center: center, window: window, id: id, host: host)
    }

    private static func other() -> NSWindow {
        let other = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 300, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        return other
    }

    private static func becameKey(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @Test func aWindowThatTookTheKeyboardAndStaysKeepsIt() throws {
        let shown = try Self.show()
        let other = Self.other()
        defer { shown.close(); other.close() }
        other.orderFrontRegardless()
        Self.becameKey(other)
        #expect(shown.host.focusMoved, "the keyboard went to another window that still shows: it stays there")
    }

    @Test func aWindowThatTookTheKeyboardAndLeftGivesItBack() throws {
        let shown = try Self.show()
        let other = Self.other()
        defer { shown.close() }
        other.orderFrontRegardless()
        Self.becameKey(other)
        other.close()
        #expect(!shown.host.focusMoved, "the window that took the keyboard is gone: the dialog's leave gives it back")
    }

    @Test func aPageOfTheDialogsWindowThatTookKeyIsNoMove() throws {
        let shown = try Self.show()
        defer { shown.close() }
        let page = NSWindow(contentRect: shown.window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        shown.window.addChildWindow(page, ordered: .above)
        Self.becameKey(page)
        #expect(!shown.host.focusMoved, "a page under a whole-window question took key: the person did not move the keyboard")
    }

    @Test func thePanelTakingTheKeyboardBackCancelsAMove() throws {
        let shown = try Self.show()
        let other = Self.other()
        defer { shown.close(); other.close() }
        other.orderFrontRegardless()
        Self.becameKey(other)
        Self.becameKey(shown.host.panel)
        #expect(!shown.host.focusMoved, "the app came back to the dialog: no move")
    }
}
