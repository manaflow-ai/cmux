struct SessionIndexTablePopoverPresentation {
    enum Content {
        case section(
            section: IndexSection,
            search: SessionSearchFn,
            loadSnapshot: DirectorySnapshotFn,
            beginSessionDrag: SessionDragBeginAction,
            onResume: ((SessionEntry) -> Void)?,
            onOpen: ((SessionEntry) -> Void)?
        )
        case transcript(SessionEntry, onResume: ((SessionEntry) -> Void)?)
    }

    let identity: SessionIndexTablePopoverIdentity
    let content: Content
    let onDismiss: @MainActor () -> Void
    /// Focus-only action forwarded to the shared session-row menu.
    let onFocus: ((SessionEntry) -> Void)?

    init(
        identity: SessionIndexTablePopoverIdentity,
        content: Content,
        onDismiss: @escaping @MainActor () -> Void,
        onFocus: ((SessionEntry) -> Void)? = nil
    ) {
        self.identity = identity
        self.content = content
        self.onDismiss = onDismiss
        self.onFocus = onFocus
    }

    func hasEquivalentContent(to other: Self) -> Bool {
        switch (content, other.content) {
        case let (.section(lhs, _, _, _, _, _), .section(rhs, _, _, _, _, _)):
            return lhs == rhs
        case let (.transcript(lhs, _), .transcript(rhs, _)):
            return lhs == rhs
        default:
            return false
        }
    }
}
