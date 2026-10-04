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
    static func escape(_ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
    }

    @Test func escapeCancelsASheetOnTheWindowItReaches() async throws {
        let router = KeyOwnershipMatrixTests.services().keyRouter!
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        var response: NSApplication.ModalResponse?
        // A sheet attaches only to a window on screen (WINDOW-LITE: small, off the main area, closed at the end).
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        window.beginSheet(sheet) { response = $0 }
        for _ in 0..<50 where window.attachedSheet == nil { try? await Task.sleep(for: .milliseconds(20)) }
        try #require(window.attachedSheet === sheet)
        #expect(router.interceptKeyDown(Self.escape(window), in: window), "Escape is consumed")
        #expect(window.attachedSheet == nil)
        for _ in 0..<50 where response == nil { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(response == .cancel)
        // With no sheet, Escape is not the dispatcher's.
        #expect(!router.interceptKeyDown(Self.escape(window), in: window))
        window.orderOut(nil)
        window.close()
    }
}
