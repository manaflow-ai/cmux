import AppKit
import CmuxWorkspaces

// MARK: - Minimal visibility policy

/// Pure mount/compact policy for todo affordances in compact sidebar rows.
/// Checklist content must stay mounted while it is visible or anchoring an
/// open/add-requested popover; status stays visible only when the row is in
/// compact detail mode and the workspace has opted into status display.
struct SidebarWorkspaceTodoMinimalVisibility: Equatable {
    let itemCount: Int
    let addFieldActivationToken: Int
    let isPopoverPresented: Bool
    let canAddItems: Bool
    let hidesAllDetails: Bool
    let taskStatus: WorkspaceTaskStatus?
    let featureEnabled: Bool

    var showsChecklistSection: Bool {
        itemCount > 0 || (canAddItems && (addFieldActivationToken > 0 || isPopoverPresented))
    }

    var showsCompactStatus: Bool {
        featureEnabled && hidesAllDetails && taskStatus != nil
    }
}

// MARK: - Display policy

/// Pure display ordering/clamping for the sidebar checklist. Kept free of
/// UI frameworks so it is unit-testable.
enum SidebarWorkspaceChecklistDisplayPolicy {
    /// How many items the expanded list shows before collapsing the rest
    /// behind a "… N more" row.
    static let visibleItemLimit = 7

    /// Completed items sink below unchecked ones; order is otherwise stable.
    static func orderedItems(_ items: [WorkspaceChecklistItem]) -> [WorkspaceChecklistItem] {
        items.filter { $0.state != .completed } + items.filter { $0.state == .completed }
    }

    /// Clamps the ordered list at ``visibleItemLimit`` unless fully expanded.
    static func clampedItems(
        _ orderedItems: [WorkspaceChecklistItem],
        showsAllItems: Bool
    ) -> (visible: [WorkspaceChecklistItem], hiddenCount: Int) {
        guard !showsAllItems, orderedItems.count > visibleItemLimit else {
            return (orderedItems, 0)
        }
        return (
            Array(orderedItems.prefix(visibleItemLimit)),
            orderedItems.count - visibleItemLimit
        )
    }
}

// MARK: - Actions bundle

/// Closure bundle the row passes below the snapshot boundary (rows receive
/// immutable value snapshots plus action closures only; see the
/// snapshot-boundary rule in CLAUDE.md).
struct SidebarWorkspaceChecklistActions {
    let setItemState: @MainActor (UUID, WorkspaceChecklistItem.State) -> Void
    let removeItem: @MainActor (UUID) -> Void
    let addItem: @MainActor (String) -> Void
    /// Rewrites one item's text (tap-to-edit).
    let editItem: @MainActor (UUID, String) -> Void
    /// Moves one item toward a new 0-based position (within its completion
    /// partition; used by the todo pane's drag reorder).
    let moveItem: @MainActor (UUID, Int) -> Void
    /// Opens the workspace's todo pane (checklist popover footer).
    let openPane: @MainActor () -> Void
    /// Opens an image picker and attaches selected images to one item.
    let addAttachments: @MainActor (UUID) -> Void
    /// Removes one attachment reference from one item.
    let removeAttachment: @MainActor (UUID, UUID) -> Void
    /// Opens one item's attachments in Quick Look.
    let openAttachments: @MainActor (UUID, UUID?) -> Void
}
