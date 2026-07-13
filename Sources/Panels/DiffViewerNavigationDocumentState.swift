@MainActor
final class DiffViewerNavigationDocumentState {
    private struct Snapshot {
        let documentConfirmed: Bool
        let focusConfirmed: Bool
        let editableFocused: Bool
    }

    private(set) var documentConfirmed = false
    private var focusConfirmed = false
    private var editableFocused = false
    private var stateBeforeProvisionalNavigation: Snapshot?

    var canHandleNavigation: Bool {
        documentConfirmed && focusConfirmed && !editableFocused
    }

    func update(viewer: Bool, editable: Bool) {
        documentConfirmed = viewer
        focusConfirmed = true
        editableFocused = editable
    }

    func invalidateFocusConfirmation() {
        focusConfirmed = false
    }

    func navigationDidStart() {
        if stateBeforeProvisionalNavigation == nil {
            stateBeforeProvisionalNavigation = Snapshot(
                documentConfirmed: documentConfirmed,
                focusConfirmed: focusConfirmed,
                editableFocused: editableFocused
            )
        }
        documentConfirmed = false
        focusConfirmed = false
        editableFocused = false
    }

    func navigationDidCommit() {
        stateBeforeProvisionalNavigation = nil
    }

    func navigationDidCancel() {
        guard let snapshot = stateBeforeProvisionalNavigation else { return }
        documentConfirmed = snapshot.documentConfirmed
        focusConfirmed = snapshot.focusConfirmed
        editableFocused = snapshot.editableFocused
        stateBeforeProvisionalNavigation = nil
    }
}
