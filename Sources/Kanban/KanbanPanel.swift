import AppKit
import Foundation

/// A workspace panel that hosts the Kanban task board.
///
/// Mirrors the structure of ``AgentSessionPanel`` but is intentionally simpler:
/// the board carries no per-provider runtime state, so its title and dirty flag
/// are static. Board data lives in the renderer session's coordinator (and on
/// disk via ``KanbanBoardRepository``), not on the panel.
@MainActor
final class KanbanPanel: Panel {
    let id: UUID
    let panelType: PanelType = .kanban
    private(set) var workspaceId: UUID
    let rendererKind: KanbanRendererKind
    let workingDirectory: String?
    let rendererSession = KanbanWebRendererSession()

    let displayTitle: String
    var displayIcon: String? { "rectangle.split.3x1" }
    let isDirty: Bool = false

    init(
        workspaceId: UUID,
        rendererKind: KanbanRendererKind = .react,
        workingDirectory: String? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.workingDirectory = workingDirectory
        self.displayTitle = String(localized: "kanban.panel.title", defaultValue: "Kanban")
    }

    func focus() {
        rendererSession.focus()
    }

    func unfocus() {
        rendererSession.unfocus()
    }

    func close() {
        rendererSession.close()
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
