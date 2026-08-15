struct SessionIndexTablePopoverPresentation {
    enum Content {
        case section(
            section: IndexSection,
            search: SessionSearchFn,
            loadSnapshot: DirectorySnapshotFn,
            beginSessionDrag: SessionDragBeginAction,
            onResume: ((SessionEntry) -> Void)?
        )
        case transcript(SessionEntry, onResume: ((SessionEntry) -> Void)?)
    }

    let identity: SessionIndexTablePopoverIdentity
    let content: Content
    let onDismiss: @MainActor () -> Void

    func hasEquivalentContent(to other: Self) -> Bool {
        switch (content, other.content) {
        case let (.section(lhs, _, _, _, _), .section(rhs, _, _, _, _)):
            return lhs == rhs
        case let (.transcript(lhs, _), .transcript(rhs, _)):
            return lhs == rhs
        default:
            return false
        }
    }
}
