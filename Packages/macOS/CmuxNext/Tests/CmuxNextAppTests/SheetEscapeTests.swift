import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// A sheet on a cmux window (Import Keymap… / Export Keymap…, any save or
/// open panel) closes on Escape and gives the keyboard back, also when the
/// key reaches the window under the sheet (the app is not active, or a
/// synthetic key from automation): the dispatcher ends the sheet with
/// Cancel, and windowDidEndSheet restores the focus.
@MainActor
struct SheetEscapeTests {
    static func key(_ window: NSWindow, code: UInt16 = 53, chars: String = "\u{1B}", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Headless: only an unmodified Escape asks to end a sheet, and the key
    /// is consumed only when a sheet ended.
    @Test func onlyUnmodifiedEscapeEndsASheet() {
        let router = KeyOwnershipMatrixTests.services().keyRouter!
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        var asked: [NSWindow] = []
        var hasSheet = true
        router.endTopmostSheet = { asked.append($0); return hasSheet }
        #expect(router.interceptKeyDown(Self.key(window), in: window), "Escape over a sheet is consumed")
        #expect(asked.count == 1 && asked.first === window)
        #expect(router.cancelsAttachedSheet(Self.key(window, modifiers: .shift), in: window) == false)
        #expect(router.cancelsAttachedSheet(Self.key(window, code: 0, chars: "a"), in: window) == false)
        #expect(asked.count == 1)
        hasSheet = false
        #expect(router.cancelsAttachedSheet(Self.key(window), in: window) == false, "With no sheet, Escape is not the dispatcher's")
    }

    /// GUI lane (cmux-lawrence-2): a real sheet ends with Cancel.
    @Test(.enabled(if: WindowSession.available, WindowSession.reason))
    func escapeCancelsASheetOnTheWindowItReaches() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let router = KeyOwnershipMatrixTests.services().keyRouter!
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        let alert = NSAlert()
        alert.messageText = "sheet"
        var response: NSApplication.ModalResponse?
        alert.beginSheetModal(for: window) { response = $0 }
        try #require(window.attachedSheet != nil)
        #expect(router.interceptKeyDown(Self.key(window), in: window), "Escape is consumed")
        #expect(window.attachedSheet == nil)
        #expect(response == .cancel)
        #expect(!router.interceptKeyDown(Self.key(window), in: window))
        window.close()
    }
}
