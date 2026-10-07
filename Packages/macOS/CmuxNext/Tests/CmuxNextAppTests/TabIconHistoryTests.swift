import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// RECOVERABLE-BY-DEFAULT for tab icons (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS):
/// a user's icon change is one undo step, undo sends the earlier icon back to
/// the daemon and redo sends the new one again; automation is not an undo step.
@MainActor @Suite struct TabIconHistoryTests {
    final class Daemon {
        var updates: [FieldUpdate<String>] = []
        var tabGone = false
    }

    private func history(_ daemon: Daemon) -> TabIconHistory {
        TabIconHistory { id, update in
            guard !daemon.tabGone, id == "tab_1" else { return false }
            daemon.updates.append(update)
            return true
        }
    }

    /// An undo manager driven by explicit groups (no run loop in a test).
    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private func step(_ manager: UndoManager, _ body: () -> Void) {
        manager.beginUndoGrouping()
        body()
        manager.endUndoGrouping()
    }

    @Test func aUserIconChangeIsOneUndoStepAndRedoSetsItAgain() {
        let daemon = Daemon(), undo = undoManager(), history = history(daemon)
        step(undo) { history.change("tab_1", from: nil, to: "star.fill", origin: .user, undoManager: undo) }
        #expect(daemon.updates == [.set("star.fill")])
        #expect(undo.canUndo)
        #expect(undo.undoActionName == TabIconStrings.undoSet)

        undo.undo()
        #expect(daemon.updates == [.set("star.fill"), .clear])
        #expect(undo.canRedo)

        undo.redo()
        #expect(daemon.updates == [.set("star.fill"), .clear, .set("star.fill")])
        #expect(undo.canUndo)
    }

    @Test func undoingARemoveBringsBackTheEarlierIcon() {
        let daemon = Daemon(), undo = undoManager(), history = history(daemon)
        step(undo) { history.change("tab_1", from: "🚀", to: nil, origin: .user, undoManager: undo) }
        #expect(daemon.updates == [.clear])
        #expect(undo.undoActionName == TabIconStrings.undoRemove)

        undo.undo()
        #expect(daemon.updates == [.clear, .set("🚀")])
    }

    @Test func undoingAReplaceRestoresTheIconBefore() {
        let daemon = Daemon(), undo = undoManager(), history = history(daemon)
        step(undo) { history.change("tab_1", from: "🚀", to: "hammer", origin: .user, undoManager: undo) }
        undo.undo()
        #expect(daemon.updates == [.set("hammer"), .set("🚀")])
    }

    @Test func automationAndUnchangedIconsAreNotUndoSteps() {
        let daemon = Daemon(), undo = undoManager(), history = history(daemon)
        for origin in ActionOrigin.allCases where origin != .user {
            step(undo) { history.change("tab_1", from: nil, to: "star", origin: origin, undoManager: undo) }
        }
        step(undo) { history.change("tab_1", from: "star", to: "star", origin: .user, undoManager: undo) }
        #expect(daemon.updates.count == ActionOrigin.allCases.count)
        // An empty group may stay on the stack; undoing it sends nothing.
        while undo.canUndo { undo.undo() }
        #expect(daemon.updates.count == ActionOrigin.allCases.count)
    }

    @Test func aGoneTabIsNotAnUndoStep() {
        let daemon = Daemon(), undo = undoManager(), history = history(daemon)
        daemon.tabGone = true
        step(undo) { history.change("tab_1", from: nil, to: "star", origin: .user, undoManager: undo) }
        daemon.tabGone = false
        while undo.canUndo { undo.undo() }
        #expect(daemon.updates.isEmpty)
    }
}
