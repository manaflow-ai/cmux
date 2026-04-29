import AppKit
import Foundation

@MainActor
protocol WorkspaceSurfaceRegistryProtocol: AnyObject {
    func mountContent(
        _ content: WorkspacePaneContent,
        contentId: UUID,
        in slotView: WorkspaceLayoutPaneContentSlotView,
        activeDropZone: DropZone?,
        onPresentationChange: (() -> Void)?
    )

    func unmountContent(
        _ content: WorkspacePaneContent,
        contentId: UUID,
        from slotView: WorkspaceLayoutPaneContentSlotView
    )

    func reconcileViewportLifecycle(
        _ content: WorkspacePaneContent,
        contentId: UUID,
        in slotView: WorkspaceLayoutPaneContentSlotView,
        reason: String
    )

    func presentationFacts(
        _ content: WorkspacePaneContent,
        contentId: UUID
    ) -> WorkspaceSurfacePresentationFacts
}
