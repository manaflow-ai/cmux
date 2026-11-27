#if os(iOS)
struct ChatArtifactViewerActionsMenuActions {
    let prepareShare: (String) -> Void
    let prepareSave: (String) -> Void
    let toggleSearch: (String) -> Void
    let toggleGoToLine: (String) -> Void
    let requestTop: (String) -> Void
    let requestBottom: (String) -> Void
    let toggleLineNumbers: (String) -> Void
    let toggleWordWrap: (String) -> Void
    let selectMarkdownMode: (String, ChatArtifactMarkdownMode) -> Void
    let notifyCopied: () -> Void
    let notifyPathCopied: () -> Void
    let performFileAction: @MainActor (ChatArtifactAction, ChatArtifactViewerPageSnapshot) -> Void
}
#endif
