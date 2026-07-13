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
    private var provisionalNavigation: (id: ObjectIdentifier?, snapshot: Snapshot)?
    private var focusConfirmationBeforeEditableTransition: Bool?

    var canHandleNavigation: Bool {
        documentConfirmed && focusConfirmed && !editableFocused
    }

    func update(viewer: Bool, editable: Bool) {
        documentConfirmed = viewer
        focusConfirmed = true
        editableFocused = editable
        focusConfirmationBeforeEditableTransition = nil
    }

    func invalidateFocusConfirmation() {
        focusConfirmed = false
    }

    func beginEditableFocusTransition() {
        if focusConfirmationBeforeEditableTransition == nil {
            focusConfirmationBeforeEditableTransition = focusConfirmed
        }
        focusConfirmed = false
    }

    func editableFocusTransitionDidFail() {
        guard let previous = focusConfirmationBeforeEditableTransition else { return }
        focusConfirmed = previous
        focusConfirmationBeforeEditableTransition = nil
    }

    func navigationDidStart(id: ObjectIdentifier?) {
        let snapshot = provisionalNavigation?.snapshot ?? Snapshot(
                documentConfirmed: documentConfirmed,
                focusConfirmed: focusConfirmed,
                editableFocused: editableFocused
            )
        provisionalNavigation = (id, snapshot)
        documentConfirmed = false
        focusConfirmed = false
        editableFocused = false
        focusConfirmationBeforeEditableTransition = nil
    }

    func navigationDidCommit(id: ObjectIdentifier?) {
        guard provisionalNavigation?.id == id else { return }
        provisionalNavigation = nil
    }

    func navigationDidCancel(id: ObjectIdentifier?) {
        guard let navigation = provisionalNavigation, navigation.id == id else { return }
        let snapshot = navigation.snapshot
        documentConfirmed = snapshot.documentConfirmed
        focusConfirmed = snapshot.focusConfirmed
        editableFocused = snapshot.editableFocused
        provisionalNavigation = nil
    }
}
