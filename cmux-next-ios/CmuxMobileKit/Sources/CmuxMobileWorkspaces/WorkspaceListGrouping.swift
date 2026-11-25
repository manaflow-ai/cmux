import CmuxMobileModel
import Foundation

/// The Mac sidebar's Group ▸ Group by None / Group by Folder (`sidebar.groupBy`), for the
/// phone's own Workspaces list: a Mac's loose rows under one header per folder. It is this
/// iPhone's view of the list, kept on the phone; the Mac's sidebar keeps its own setting.
public enum WorkspaceListGrouping: String, CaseIterable, Hashable, Sendable {
    case none, folder

    /// The Mac's menu titles.
    public var title: String {
        switch self {
        case .none: "Group by None"
        case .folder: "Group by Folder"
        }
    }

    public var systemImage: String {
        switch self {
        case .none: "list.bullet"
        case .folder: "folder"
        }
    }

    /// Where the phone keeps the choice.
    public static let defaultsKey = "cmuxMobile.workspaces.groupBy"

    /// One folder's rows: its folder ("" when no tab reports one) and its workspaces in order.
    public struct Bucket: Hashable, Sendable {
        public var folder: String
        public var workspaces: [Workspace]
    }

    /// Group by Folder's buckets, as the Mac's `SidebarLayout.folderBuckets`: the folders in the
    /// order their first rows show, the rows without a folder last.
    public static func buckets(_ workspaces: [Workspace]) -> [Bucket] {
        var order: [String] = []
        var members: [String: [Workspace]] = [:]
        for ws in workspaces {
            let folder = ws.directory.trimmingCharacters(in: .whitespaces)
            if members[folder] == nil { order.append(folder) }
            members[folder, default: []].append(ws)
        }
        if let none = order.firstIndex(of: ""), none != order.count - 1 { order.append(order.remove(at: none)) }
        return order.map { Bucket(folder: $0, workspaces: members[$0] ?? []) }
    }

    /// One section of the list's Workspaces part: a group's run, a run of loose rows, or (Group
    /// by Folder) one folder's loose rows.
    public struct Section: Hashable, Sendable, Identifiable {
        public var id: String
        public var macID: String
        public var group: MacWorkspaceGroup?
        /// Group by Folder: the folder ("" for no folder) whose header comes first.
        public var folder: String?
        public var workspaces: [Workspace]
    }

    /// The Workspaces part's sections in order. Group by None: the Mac's runs as they are. Group by
    /// Folder, as the Mac's sidebar: each Mac's groups as they are, then a header per folder over
    /// all its loose rows. A list in the phone's own order (no Mac order, `macID` "") stays flat.
    public static func arrange(_ sections: [RecentSection], by grouping: WorkspaceListGrouping) -> [Section] {
        let plain = sections.map { Section(id: $0.id, macID: $0.macID, group: $0.group, folder: nil, workspaces: $0.workspaces) }
        guard grouping == .folder else { return plain }
        var result: [Section] = []
        var macs: [String] = []
        var loose: [String: [Workspace]] = [:]
        for section in plain {
            if !macs.contains(section.macID) { macs.append(section.macID) }
            if section.group == nil, !section.macID.isEmpty {
                loose[section.macID, default: []] += section.workspaces
            }
        }
        for mac in macs {
            result += plain.filter { $0.macID == mac && ($0.group != nil || mac.isEmpty) }
            for bucket in buckets(loose[mac] ?? []) {
                result.append(Section(id: "folder.\(mac).\(bucket.folder)", macID: mac, group: nil, folder: bucket.folder,
                                      workspaces: bucket.workspaces))
            }
        }
        return result
    }

    /// A folder header's title, as the Mac's `SidebarFolderTitle`: the folder's last component,
    /// `~` and `/` as they are, "No Folder" for none.
    public static func title(_ folder: String) -> String {
        if folder.isEmpty { return "No Folder" }
        if folder == "~" || folder == "/" { return folder }
        return folder.split(separator: "/").last.map(String.init) ?? folder
    }
}
