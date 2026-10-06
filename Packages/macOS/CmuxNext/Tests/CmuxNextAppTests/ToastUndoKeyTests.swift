import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// TOAST-UNDO-KEY (R96 with the dialogs lead): Cmd-Z in a window that shows
/// an undo toast runs the newest one through the key dispatcher, but only
/// when the focused responder has nothing of its own to undo; otherwise
/// Cmd-Z goes on to the responder (Edit > Undo) as before.
@MainActor
struct ToastUndoKeyTests {
    static func key(_ window: NSWindow, _ chars: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func commandZRunsTheNewestUndoToast() {
        let router = KeyOwnershipMatrixTests.services().keyRouter!
        let toasts = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        router.undoToasts = toasts
        let window = Self.window()
        var ran = 0
        toasts.show(CmuxToast(id: "hid", message: "Hid", action: .undo(), duration: .seconds(5)), in: window).onAction = { ran += 1 }
        #expect(router.interceptKeyDown(Self.key(window, "z", 6, .command), in: window), "Cmd-Z is consumed")
        #expect(ran == 1)
        // Cmd-Shift-Z (redo) and a plain Z are not the toast's.
        toasts.show(CmuxToast(id: "hid2", message: "Hid", action: .undo(), duration: .seconds(5)), in: window).onAction = { ran += 1 }
        _ = router.interceptKeyDown(Self.key(window, "z", 6, [.command, .shift]), in: window)
        _ = router.interceptKeyDown(Self.key(window, "z", 6, []), in: window)
        #expect(ran == 1)
    }

    @Test func withoutAnUndoToastCommandZIsNotTaken() {
        let router = KeyOwnershipMatrixTests.services().keyRouter!
        let toasts = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        router.undoToasts = toasts
        let window = Self.window()
        toasts.show(CmuxToast(id: "saved", message: "Saved"), in: window)
        #expect(!router.interceptKeyDown(Self.key(window, "z", 6, .command), in: window))
    }
}
