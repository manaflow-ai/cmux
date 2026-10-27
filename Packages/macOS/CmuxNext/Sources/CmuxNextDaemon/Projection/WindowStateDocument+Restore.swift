public import Foundation

extension WindowStateDocument {
    /// A saved window as the app restores it from its records (`WindowRegistry(records:)` builds from these).
    public struct RestoredWindow: Sendable, Equatable {
        /// The window's id; its first record (front first) gives the rest.
        public let id: String
        /// Its records' workspaces (the shown one for an older record that lists none), less those a window
        /// further front took.
        public internal(set) var workspaceIDs: [String]
        public let frame: WindowFrame?
        public let display: String?
        /// Nil for the default profile.
        public let profile: ProfileID?
        /// One of its records was closed by the user.
        public internal(set) var isClosed: Bool
    }

    /// The windows `records` restore, front first: the app's window recency after a relaunch. A workspace listed by
    /// two records stays with the frontmost, a record left with none is dropped (a window exists only while it holds
    /// a workspace), and the records of one id make one window. Pure, so the launch picks the window it shows first
    /// by this one rule, off the main thread too (``frontWindow(of:mirrors:)``).
    public static func restoredWindows(_ records: [WindowRecord]) -> [RestoredWindow] {
        var byID: [String: RestoredWindow] = [:]
        var order: [String] = []
        var owned = Set<String>()
        for record in records.sorted(by: { $0.order < $1.order }) {
            var ids = record.workspaceKeys.map(\.rawValue)
            if ids.isEmpty, let shown = record.workspaceKey?.rawValue { ids = [shown] }
            ids = ids.filter { owned.insert($0).inserted }
            guard !ids.isEmpty else { continue }
            if var window = byID[record.id] {
                window.workspaceIDs += ids
                window.isClosed = window.isClosed || record.isClosed
                byID[record.id] = window
            } else {
                order.append(record.id)
                byID[record.id] = RestoredWindow(id: record.id, workspaceIDs: ids, frame: record.frame, display: record.display,
                                                 profile: record.profile, isClosed: record.isClosed)
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// The window the launch shows first: the frontmost restored window that keeps a workspace `mirrors` holds
    /// (the app's store has it, by `WorkspaceModel.id`). Nil when none does.
    public static func frontWindow(of records: [WindowRecord], mirrors: (String) -> Bool) -> RestoredWindow? {
        restoredWindows(records).first { $0.workspaceIDs.contains(where: mirrors) }
    }

    /// The window the launch shows first while the provisional store holds `tree` (it indexes a workspace by
    /// `WorkspaceModel.identity`, the ids the records list).
    public func frontWindow(in tree: DaemonTree) -> RestoredWindow? {
        let workspaces = Set(tree.workspaces.map { WorkspaceModel.identity($0) })
        return Self.frontWindow(of: windows, mirrors: { workspaces.contains($0) })
    }
}

extension LaunchSnapshot {
    /// `session`'s launch snapshot, found as `DaemonService.showLaunchSnapshot` finds it; nil when there is none or
    /// it cannot be used. It reads the file: call it off the main thread.
    public static func saved(session: String, stateDirectory: URL?, location: LaunchSnapshotLocation = LaunchSnapshotLocation()) -> Self? {
        guard let path = location.path(session: session) ?? LaunchSnapshotLocation.find(session: session, in: stateDirectory) else { return nil }
        return try? load(path: path, session: session)
    }

    /// The saved window the launch shows first from this snapshot; nil without window records.
    public var frontWindow: WindowStateDocument.RestoredWindow? {
        windows?.frontWindow(in: tree)
    }
}
