import Foundation

/// Captures native workspace targets once, before an asynchronous menu action
/// or a close confirmation. Shared by the classic sidebar and extension host.
/// A new or reordered workspace must never broaden an already captured close.
struct SidebarClassicMenuParity: Equatable, Sendable {
    enum CloseSelection: String, CaseIterable, Sendable {
        case selected
        case others
        case above
        case below
    }

    struct ClosePlan: Equatable, Sendable {
        let anchorID: UUID
        let workspaceIDs: [UUID]

        /// Target loss narrows the confirmed operation; it never selects
        /// replacement workspaces by index, title, group or current selection.
        func survivingWorkspaceIDs(in liveWorkspaceIDs: [UUID]) -> [UUID] {
            let live = Set(liveWorkspaceIDs)
            return workspaceIDs.filter(live.contains)
        }
    }

    let nativeOrder: [UUID]
    let anchorID: UUID
    let selectedWorkspaceIDs: [UUID]

    /// A context click outside the current selection acts only on the clicked
    /// workspace. Inside the selection it retains native relative ordering.
    init?(nativeOrder: [UUID], anchorID: UUID, selectedWorkspaceIDs: [UUID]) {
        guard !nativeOrder.isEmpty, Set(nativeOrder).count == nativeOrder.count,
              nativeOrder.contains(anchorID) else { return nil }
        self.nativeOrder = nativeOrder
        self.anchorID = anchorID
        let selected = Set(selectedWorkspaceIDs)
        self.selectedWorkspaceIDs = selected.contains(anchorID)
            ? nativeOrder.filter(selected.contains)
            : [anchorID]
    }

    func closePlan(_ selection: CloseSelection) -> ClosePlan {
        let ids: [UUID]
        switch selection {
        case .selected:
            ids = selectedWorkspaceIDs
        case .others:
            let keep = Set(selectedWorkspaceIDs)
            ids = nativeOrder.filter { !keep.contains($0) }
        case .above:
            ids = Array(nativeOrder.prefix { $0 != anchorID })
        case .below:
            let index = nativeOrder.firstIndex(of: anchorID)!
            ids = Array(nativeOrder.dropFirst(index + 1))
        }
        return ClosePlan(anchorID: anchorID, workspaceIDs: ids)
    }

    func canClose(_ selection: CloseSelection) -> Bool {
        !closePlan(selection).workspaceIDs.isEmpty
    }
}
