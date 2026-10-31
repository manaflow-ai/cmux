import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import Testing

/// The user, 2026-10-29: "invite to cmux-next dialog after cmd shift p is laggy". Home's sheets
/// were AppKit sheets (`beginSheet`): the slide-in runs a nested modal run loop on the main thread
/// (`NSSheetMoveHelper _doAnimation`, ~100 ms in a profile of a fresh app, more with a busy window),
/// and every frame of it re-renders the parent's dimming mask (`NSSheetEffectDimmingView
/// _rebuildMask`, a `cacheDisplayInRect` of the window and its child windows). Keys typed while it
/// slides wait in the queue, and the email field takes the keyboard only after it (`viewDidAppear`).
/// A Home sheet is the window's dialog overlay now, as the Share dialog is: it shows in the frame
/// of the call and its field has the keyboard at once.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeSheetOpensInstantlyTests {
    @Test func inviteShowsInTheCallsFrameAndItsFieldTakesTheFirstKey() throws {
        let window = Self.window()
        defer { Self.close(window) }
        let sheet = HomeInviteSheet(pending: [])
        var finished: [ConversationID?] = []
        sheet.onFinish = { finished.append($0) }

        let held = ContinuousClock().measure { HomeSheetPresenter().present(sheet, over: window) }

        #expect(window.attachedSheet == nil, "an AppKit sheet: its slide-in holds every key in a modal loop")
        // Measured on the main thread: the overlay path costs a few ms; the sheet's animation alone ~100 ms.
        #expect(held < .milliseconds(50), "presenting held the main thread for \(held)")
        let editor = sheet.view.window?.firstResponder as? NSText
        #expect(editor != nil && editor?.delegate === sheet.email, "the email field does not have the keyboard")
        #expect(sheet.view.window?.isVisible == true)

        sheet.cancel(nil)
        #expect(finished.count == 1)
        #expect(finished.first == .some(nil))
        #expect(WindowOverlayHost.existingHost(for: window)?.presentedHandles.isEmpty ?? true, "Cancel left the dialog up")
    }

    @Test func newChiefTakesTheKeyboardInItsNameField() throws {
        let window = Self.window()
        defer { Self.close(window) }
        let sheet = HomeNewChiefSheet()
        HomeSheetPresenter().present(sheet, over: window)
        #expect(window.attachedSheet == nil)
        let editor = sheet.view.window?.firstResponder as? NSText
        #expect(editor != nil && editor?.delegate === sheet.name, "the name field does not have the keyboard")
        sheet.cancel(nil)
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        let panel = WindowOverlayHost.existingHost(for: window)?.panel
        window.close()
        panel?.close()
    }
}
