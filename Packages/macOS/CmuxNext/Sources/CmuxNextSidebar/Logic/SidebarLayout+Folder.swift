nonisolated extension SidebarLayout {
    /// Group by Folder's buckets of a section's loose rows: the folders in first-seen order, "no folder" ("") last, and
    /// each folder's node indices in list order.
    static func folderBuckets(_ nodes: [SidebarNode]) -> (folders: [String], members: [String: [Int]]) {
        var folders: [String] = []
        var members: [String: [Int]] = [:]
        for (index, node) in nodes.enumerated() {
            guard case let .workspace(ws) = node else { continue }
            let folder = ws.folder ?? ""
            if members[folder] == nil { folders.append(folder) }
            members[folder, default: []].append(index)
        }
        if let none = folders.firstIndex(of: ""), none != folders.count - 1 { folders.append(folders.remove(at: none)) }
        return (folders, members)
    }
}
