@MainActor
public final class DiffViewerNavigationDocumentState {
    public private(set) var documentConfirmed = false
    private var focusConfirmed = false
    private var editableFocused = false
    private var rendererReady = false
    private var provisionalNavigation: (id: ObjectIdentifier?, snapshot: DiffViewerNavigationDocumentSnapshot)?
    private var focusConfirmationBeforeEditableTransition: Bool?

    /// Creates a state with no confirmed diff viewer document.
    public init() {}

    public var canHandleNavigation: Bool {
        documentConfirmed && focusConfirmed && !editableFocused && rendererReady
    }

    /// Whether the document is a ready diff viewer that owns find-in-page.
    /// Unlike `canHandleNavigation`, focus does not matter: Cmd+F must open
    /// the viewer's find bar even while an in-page editor has focus.
    public var canHandleFindCommands: Bool {
        documentConfirmed && rendererReady
    }

#if DEBUG
    public var debugStateDescription: String {
        "document=\(documentConfirmed ? 1 : 0) focus=\(focusConfirmed ? 1 : 0) " +
            "editable=\(editableFocused ? 1 : 0) ready=\(rendererReady ? 1 : 0) " +
            "provisional=\(provisionalNavigation == nil ? 0 : 1)"
    }
#endif

    public func update(viewer: Bool, editable: Bool, rendererReady: Bool) {
        documentConfirmed = viewer
        focusConfirmed = true
        editableFocused = editable
        self.rendererReady = rendererReady
        focusConfirmationBeforeEditableTransition = nil
    }

    public func invalidateFocusConfirmation() {
        focusConfirmed = false
    }

    public func beginEditableFocusTransition() {
        if focusConfirmationBeforeEditableTransition == nil {
            focusConfirmationBeforeEditableTransition = focusConfirmed
        }
        focusConfirmed = false
    }

    public func editableFocusTransitionDidFail() {
        guard let previous = focusConfirmationBeforeEditableTransition else { return }
        focusConfirmed = previous
        focusConfirmationBeforeEditableTransition = nil
    }

    public func navigationDidStart(id: ObjectIdentifier?) {
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

    public func navigationDidCommit(id: ObjectIdentifier?) {
        guard provisionalNavigation?.id == id else { return }
        provisionalNavigation = nil
    }

    public func navigationDidCancel(id: ObjectIdentifier?) {
        guard let navigation = provisionalNavigation, navigation.id == id else { return }
        let snapshot = navigation.snapshot
        documentConfirmed = snapshot.documentConfirmed
        focusConfirmed = snapshot.focusConfirmed
        editableFocused = snapshot.editableFocused
        rendererReady = snapshot.rendererReady
        provisionalNavigation = nil
    }

    public func rendererDidBecomeUnavailable() {
        rendererReady = false
    }
}
