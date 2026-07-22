@MainActor
final class DiffViewerNavigationDocumentState {
    private(set) var documentConfirmed = false
    private var focusConfirmed = false
    private var editableFocused = false
    private var rendererReady = false
    private var provisionalNavigation: (id: ObjectIdentifier?, snapshot: DiffViewerNavigationDocumentSnapshot)?
    private var focusConfirmationBeforeEditableTransition: Bool?

    var canHandleNavigation: Bool {
        documentConfirmed && focusConfirmed && !editableFocused && rendererReady
    }

    func update(viewer: Bool, editable: Bool, rendererReady: Bool) {
        documentConfirmed = viewer
        focusConfirmed = true
        editableFocused = editable
        self.rendererReady = rendererReady
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
        let snapshot = provisionalNavigation?.snapshot ?? DiffViewerNavigationDocumentSnapshot(
                documentConfirmed: documentConfirmed,
                focusConfirmed: focusConfirmed,
                editableFocused: editableFocused,
                rendererReady: rendererReady
            )
        provisionalNavigation = (id, snapshot)
        documentConfirmed = false
        focusConfirmed = false
        editableFocused = false
        rendererReady = false
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
        rendererReady = snapshot.rendererReady
        provisionalNavigation = nil
    }

    func rendererDidBecomeUnavailable() {
        rendererReady = false
    }
}
