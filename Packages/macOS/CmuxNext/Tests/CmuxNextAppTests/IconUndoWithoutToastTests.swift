import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// An icon change is not destructive: it is an undo step on the window's stack, with no toast
/// (Lawrence 2026-10-18).
@MainActor
@Suite(.closesItsWindows)
struct IconUndoWithoutToastTests {
    @Test func anIconChangeUndoesFromEditUndoWithoutAToast() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let manager = try #require(window.undoManager)
        var undone = false
        IconHistory.registerUndo(IconStrings.undoSet, in: window) { undone = true }
        #expect(CmuxToastCenter.shared.toasts(in: window).isEmpty)
        #expect(manager.undoActionName == IconStrings.undoSet)
        manager.undo()
        #expect(undone)
    }
}
