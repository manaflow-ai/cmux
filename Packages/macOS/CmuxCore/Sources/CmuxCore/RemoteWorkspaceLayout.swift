/// The shared pane projection used by the Cloud sidebar and CLI.
///
/// Panes follow screen/layout order, tabs follow tab order, and the active tab
/// owns the row. Missing coordinates retain arrival order. Pane-less placements
/// follow the panes in resource-kind order without dropping any placement.
/// Grouping is linear in placement count. Ordering costs
/// O(K log K + sum(T log T) + L log L) for K panes, T tabs per pane,
/// and L pane-less placements; no artificial limit drops user-owned records.
public struct RemoteWorkspaceLayout: Sendable {
    /// Pane rows followed by pane-less resources, expressed as source-array indices.
    public let rows: [RemoteWorkspaceLayoutRow]

    private enum ScreenIdentity: Hashable {
        case id(String)
        case index(Int)
        case unknown
    }

    private struct PaneKey: Hashable {
        let screen: ScreenIdentity
        let paneID: String
    }

    private struct Pane {
        let coordinates: RemoteWorkspacePlacement
        var tabIndices: [Int]
    }

    /// Plans a snapshot without retaining application objects or mutable global state.
    public nonisolated init(placements: [RemoteWorkspacePlacement]) {
        var panes: [Pane] = []
        var paneIndexByKey: [PaneKey: Int] = [:]
        var loose: [Int] = []
        for (index, placement) in placements.enumerated() {
            guard let paneID = placement.paneID, !paneID.isEmpty else {
                loose.append(index)
                continue
            }
            let screen: ScreenIdentity
            if let screenID = placement.screenID, !screenID.isEmpty {
                screen = .id(screenID)
            } else if let screenIndex = placement.screenIndex {
                screen = .index(screenIndex)
            } else {
                screen = .unknown
            }
            let key = PaneKey(screen: screen, paneID: paneID)
            if let paneIndex = paneIndexByKey[key] {
                panes[paneIndex].tabIndices.append(index)
            } else {
                paneIndexByKey[key] = panes.count
                panes.append(Pane(coordinates: placement, tabIndices: [index]))
            }
        }
        let orderedPanes = panes.enumerated().sorted { left, right in
            let leftPlacement = left.element.coordinates
            let rightPlacement = right.element.coordinates
            return (leftPlacement.screenIndex ?? Int.max, leftPlacement.paneIndex ?? Int.max, left.offset)
                < (rightPlacement.screenIndex ?? Int.max, rightPlacement.paneIndex ?? Int.max, right.offset)
        }.map(\.element)
        var rows: [RemoteWorkspaceLayoutRow] = []
        for pane in orderedPanes {
            let tabs = pane.tabIndices.sorted { left, right in
                (placements[left].tabIndex ?? Int.max, left) < (placements[right].tabIndex ?? Int.max, right)
            }
            let shown = tabs.first { placements[$0].focused } ?? tabs[0]
            rows.append(RemoteWorkspaceLayoutRow(shownIndex: shown, hiddenIndices: tabs.filter { $0 != shown }))
        }
        let orderedLoose = loose.sorted { left, right in
            (placements[left].kindOrder, left) < (placements[right].kindOrder, right)
        }
        rows.append(contentsOf: orderedLoose.map { RemoteWorkspaceLayoutRow(shownIndex: $0, hiddenIndices: []) })
        self.rows = rows
    }
}
