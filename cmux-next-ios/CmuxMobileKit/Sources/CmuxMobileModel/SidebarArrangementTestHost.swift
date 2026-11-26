#if !os(iOS)
import Foundation

// The macOS test host only. The phone's arrangement rules are Rust's
// (cmux-mobile-link-ffi `workspace_arrangement`), called from
// WorkspaceArrangement.swift; the FFI xcframework has no macOS slice, so
// `swift test` on macOS (CmuxMobileLiveTests, CmuxMobileWorkspacesTests) reads
// trees through this copy. The iOS simulator run tests the Rust path. Delete
// this file once the xcframework carries a macOS slice.
extension SidebarArrangement {
    func applyOnTestHost(to workspaces: inout [Workspace], registryID: String?, legacyPinned: Set<String>) {
        let pinIndex: [String: (Int, String)] = Dictionary(
            (pins ?? []).enumerated().map { ($1.value, ($0, $1.itemID)) }, uniquingKeysWith: { first, _ in first })
        let ordered = (rows ?? []).sorted { $0.index < $1.index }
        let place: [String: Int] = Dictionary(
            ordered.enumerated().compactMap { offset, row in row.session == registryID ? (row.key, offset) : nil },
            uniquingKeysWith: { first, _ in first })
        let rowCount = ordered.count
        for i in workspaces.indices {
            let ws = workspaces[i]
            let ref = registryID.flatMap { id in ws.resourceID.map { Self.refValue(registryID: id, resourceID: $0) } }
            if let pins {
                let pin = ref.flatMap { pinIndex[$0] }
                let flagged = legacyPinned.contains(ws.id)
                workspaces[i].isPinned = pin != nil || flagged
                workspaces[i].pinIndex = pin?.0 ?? (flagged ? pins.count + i : nil)
                workspaces[i].pinItemID = pin?.1
            } else {
                workspaces[i].isPinned = legacyPinned.contains(ws.id)
                workspaces[i].pinIndex = workspaces[i].isPinned ? i : nil
                workspaces[i].pinItemID = nil
            }
            workspaces[i].sidebarIndex = rows == nil ? i : (place[ws.id] ?? rowCount + i)
            workspaces[i].group = nil
        }
        if let registryID, rows != nil, !groups.isEmpty { applyGroups(to: &workspaces, registryID: registryID) }
    }

    static func testHostIndex(_ rows: [Row], registryID: String, workspace: String, anchor: String, after: Bool) -> Int? {
        let order = rows.sorted { $0.index < $1.index }.map { "\($0.session)/\($0.key)" }
            .filter { $0 != "\(registryID)/\(workspace)" }
        guard let anchorIndex = order.firstIndex(of: "\(registryID)/\(anchor)") else { return nil }
        return after ? anchorIndex + 1 : anchorIndex
    }

    /// The Mac's mixed sidebar order with groups (cmux-next
    /// `PersonalSidebar.mixedSections`): walk every personal row by place;
    /// before row i come the groups whose `top_index` is i (members in personal
    /// order), then row i when it is loose. Workspaces without a row follow,
    /// then the groups placed after every row. Each workspace gets its place
    /// in that order and its group.
    private func applyGroups(to workspaces: inout [Workspace], registryID: String) {
        let ordered = (rows ?? []).sorted { $0.index < $1.index }
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = ordered.filter { $0.session == registryID }
        let groupOf: [String: String] = Dictionary(
            mine.compactMap { row in row.group.flatMap { byID[$0] != nil ? (row.key, $0) : nil } }, uniquingKeysWith: { first, _ in first })
        let sortedGroups = groups.sorted { $0.index < $1.index }
        var sequence: [String] = []
        func emit(_ group: MacWorkspaceGroup) {
            sequence += mine.filter { groupOf[$0.key] == group.id }.map(\.key)
        }
        for (index, row) in ordered.enumerated() {
            for group in sortedGroups where group.topIndex == index { emit(group) }
            if row.session == registryID, groupOf[row.key] == nil { sequence.append(row.key) }
        }
        let rowed = Set(mine.map(\.key))
        sequence += workspaces.map(\.id).filter { !rowed.contains($0) }
        for group in sortedGroups where group.topIndex.map({ $0 >= ordered.count }) ?? true { emit(group) }
        let position = Dictionary(sequence.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for i in workspaces.indices {
            let id = workspaces[i].id
            workspaces[i].sidebarIndex = position[id] ?? sequence.count + i
            workspaces[i].group = groupOf[id].flatMap { byID[$0] }
        }
    }
}
#endif
