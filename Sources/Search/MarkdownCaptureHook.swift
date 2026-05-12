import Foundation

/// Feeds markdown-panel contents into the global search index.
///
/// Tiny static helper — call once on load and again on every save:
///
///     CmuxMarkdownCaptureHook.feed(
///         text: editor.text,
///         windowID: window.id, workspaceID: workspace.id,
///         panelID: panel.id, anchor: file?.path ?? "",
///         index: AppDelegate.shared?.searchIndex)
///
/// Cheap enough to call inline on save; debounce at call-site if
/// needed.
public enum CmuxMarkdownCaptureHook {
    @MainActor
    public static func feed(
        text: String,
        windowID: UUID, workspaceID: UUID,
        panelID: UUID, anchor: String,
        index: SearchIndex?
    ) {
        guard let index, !text.isEmpty else { return }
        let payload = String(text.prefix(200_000))
        Task.detached(priority: .utility) {
            await index.upsert(
                windowID: windowID, workspaceID: workspaceID,
                panelID: panelID, kind: .markdown,
                anchor: anchor, text: payload)
        }
    }
}
