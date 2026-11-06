import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A move, pin or reorder is an undo step with no toast (Lawrence 2026-10-18: the "Move Undo"
/// toast "keeps on showing up every single time"): Edit > Undo still runs its inverse once,
/// and Redo after it.
@MainActor
@Suite(.closesItsWindows)
struct ToastUndoStepWithoutToastTests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    @Test func aStepWithoutAToastUndoesFromTheUndoStack() throws {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let manager = try #require(window.undoManager)
        var undone = 0
        ToastUndoStep.attach(title: "Move", filling: nil, undoManager: manager, handle: nil) { undone += 1 }
        #expect(CmuxToastCenter.shared.toasts(in: window).isEmpty, "a move showed a toast")
        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Move")
        manager.undo()
        #expect(undone == 1)
        manager.undo()
        #expect(undone == 1, "the inverse ran twice")
    }

    @Test func theInverseRegisteredDuringUndoIsTheRedo() throws {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let manager = try #require(window.undoManager)
        var moves: [String] = []
        func move(_ to: String, back: String) {
            moves.append(to)
            ToastUndoStep.attach(title: "Move", filling: nil, undoManager: manager, handle: nil) { move(back, back: to) }
        }
        move("top", back: "bottom")
        manager.undo()
        #expect(moves == ["top", "bottom"])
        #expect(manager.canRedo)
        manager.redo()
        #expect(moves == ["top", "bottom", "top"])
        #expect(CmuxToastCenter.shared.toasts(in: window).isEmpty)
    }

    /// A change sent and not answered yet: its step waits on the stack without a toast, and the
    /// reply fills it.
    @Test func aPendingStepWithoutAToastIsFilledByTheReply() throws {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let manager = try #require(window.undoManager)
        var undone = false
        let step = ToastUndoStep.pending(title: "Move", undoManager: manager, handle: nil)
        #expect(CmuxToastCenter.shared.toasts(in: window).isEmpty)
        step.fillPending(title: "Move") { undone = true }
        manager.undo()
        #expect(undone)
    }
}
