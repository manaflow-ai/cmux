import Foundation

/// Panel-owned session for the markdown panel's Monaco edit mode.
///
/// SwiftUI may recreate `MarkdownEditorRenderer` wrappers during split/tab
/// layout updates, and the edit surface unmounts entirely while the panel
/// shows the rendered preview. The session ties the WebKit coordinator (and
/// its webview, buffer, and undo stack) to the logical `MarkdownPanel`
/// instead of the transient representable instance — the same pattern as
/// ``MarkdownRendererSession`` for the preview webview.
@MainActor
final class MarkdownEditorSession {
    private let ownedCoordinator = MarkdownEditorRendererCoordinator()

    func coordinator(panel: MarkdownPanel) -> MarkdownEditorRendererCoordinator {
        ownedCoordinator.bind(panel: panel)
        return ownedCoordinator
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func revealNeedle(_ needle: String) {
        ownedCoordinator.revealNeedle(needle)
    }

    func adoptDiskContent(_ content: String, sha256: String?) {
        ownedCoordinator.adoptDiskContent(content, sha256: sha256)
    }

    func pullContent(_ completion: @escaping (String?) -> Void) {
        ownedCoordinator.pullContent(completion)
    }

    func requestSave() {
        ownedCoordinator.requestSave()
    }

    func close() {
        ownedCoordinator.close()
    }
}
