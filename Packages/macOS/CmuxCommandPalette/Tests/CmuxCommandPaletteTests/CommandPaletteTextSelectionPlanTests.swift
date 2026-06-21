import Foundation
import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite("CommandPalettePresentationModel.pendingTextSelectionPlan")
struct CommandPaletteTextSelectionPlanTests {
    private func makeModel() -> CommandPalettePresentationModel {
        let suite = "CommandPaletteTextSelectionPlanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return CommandPalettePresentationModel(defaultWorkspaceDescriptionHeight: 42, defaults: defaults)
    }

    private func renameTarget() -> CommandPaletteRenameTarget {
        CommandPaletteRenameTarget(kind: .workspace(workspaceId: UUID()), currentName: "name")
    }

    private func descriptionTarget() -> CommandPaletteWorkspaceDescriptionTarget {
        CommandPaletteWorkspaceDescriptionTarget(workspaceId: UUID(), currentDescription: "desc")
    }

    @Test("no pending behavior yields skip")
    func noPendingBehavior() {
        let model = makeModel()
        model.pendingTextSelectionBehavior = nil
        #expect(model.pendingTextSelectionPlan() == .skip)
    }

    @Test("selectAll applies only in renameInput mode")
    func selectAllGating() {
        let model = makeModel()
        model.pendingTextSelectionBehavior = .selectAll

        model.mode = .commands
        #expect(model.pendingTextSelectionPlan() == .skip)

        model.mode = .renameInput(renameTarget())
        #expect(model.pendingTextSelectionPlan() == .selectAll)

        model.mode = .renameConfirm(renameTarget(), proposedName: "x")
        #expect(model.pendingTextSelectionPlan() == .skip)

        model.mode = .workspaceDescriptionInput(descriptionTarget())
        #expect(model.pendingTextSelectionPlan() == .skip)
    }

    @Test("caretAtEnd applies in commands and renameInput, skips confirm and description")
    func caretAtEndGating() {
        let model = makeModel()
        model.pendingTextSelectionBehavior = .caretAtEnd

        model.mode = .commands
        #expect(model.pendingTextSelectionPlan() == .caretAtEnd)

        model.mode = .renameInput(renameTarget())
        #expect(model.pendingTextSelectionPlan() == .caretAtEnd)

        model.mode = .renameConfirm(renameTarget(), proposedName: "x")
        #expect(model.pendingTextSelectionPlan() == .skip)

        model.mode = .workspaceDescriptionInput(descriptionTarget())
        #expect(model.pendingTextSelectionPlan() == .skip)
    }

    @Test("the model does not clear the pending behavior")
    func planIsNonMutating() {
        let model = makeModel()
        model.pendingTextSelectionBehavior = .selectAll
        model.mode = .renameInput(renameTarget())
        _ = model.pendingTextSelectionPlan()
        // The host clears the pending behavior only after it applies a range; the
        // pure decision must leave it queued.
        #expect(model.pendingTextSelectionBehavior == .selectAll)
    }
}

@Suite("CommandPaletteInputFocusPolicy.renameInput")
struct CommandPaletteRenameInputFocusPolicyTests {
    @Test("selects all when the preference is on")
    func selectsAll() {
        let policy = CommandPaletteInputFocusPolicy.renameInput(selectsAllOnFocus: true)
        #expect(policy.focusTarget == .rename)
        #expect(policy.selectionBehavior == .selectAll)
    }

    @Test("caret at end when the preference is off")
    func caretAtEnd() {
        let policy = CommandPaletteInputFocusPolicy.renameInput(selectsAllOnFocus: false)
        #expect(policy.focusTarget == .rename)
        #expect(policy.selectionBehavior == .caretAtEnd)
    }
}
