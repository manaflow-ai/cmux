#if os(iOS)
import CoreGraphics

/// Resolves a workspace-list drag location into the native table drop presentation.
struct WorkspaceListDropProposalPolicy {
    enum Decision: Equatable {
        case into
        case insertAt
        case forbidden
    }

    let edgeInset: CGFloat

    init(edgeInset: CGFloat = 8) {
        self.edgeInset = edgeInset
    }

    func decision(
        hitItem: WorkspaceListTableItem?,
        draggedItem: WorkspaceListTableItem?,
        yOffset: CGFloat,
        rowHeight: CGFloat,
        canDropIntoGroup: Bool
    ) -> Decision {
        if case .chrome = hitItem {
            return .forbidden
        }
        guard
            case .groupHeader = hitItem,
            case .workspace = draggedItem,
            canDropIntoGroup,
            rowHeight > edgeInset * 2,
            yOffset >= edgeInset,
            yOffset <= rowHeight - edgeInset
        else {
            return .insertAt
        }
        return .into
    }
}
#endif
