import Foundation

/// Where the user was when the app last ran (design/terminal P10): the root
/// tab, and on Workspaces the open workspace (with its Mac) and its tab.
public struct LastOpenLocation: Codable, Equatable, Sendable {
    /// `RootTab.rawValue` ("home", "workspaces", "feed", "settings").
    public var rootTab: String
    public var workspaceID: String?
    public var macID: String?
    public var tabID: String?

    public static let workspacesTab = "workspaces"

    public init(rootTab: String, workspaceID: String? = nil, macID: String? = nil, tabID: String? = nil) {
        self.rootTab = rootTab
        self.workspaceID = workspaceID
        self.macID = macID
        self.tabID = tabID
    }
}

/// What a launch does with the saved location. Pure: the saved location and
/// what the store knows now in, a decision out.
public enum LastOpenRestore {
    public enum Decision: Equatable, Sendable {
        /// Nothing to restore: the app opens as usual (Home).
        case nothing
        /// The Workspaces list (the workspace is gone, or none was open).
        case showList
        /// The Workspaces list for now; the workspace's Mac has not answered
        /// yet, so decide again when the workspaces change.
        case wait
        /// Open the workspace on `tabID` (nil: its usual opening tab).
        case open(workspaceID: String, tabID: String?)
    }

    /// Restores only a Workspaces location: the workspace when it still
    /// exists, on the saved tab when that tab still exists. A Needs-you
    /// workspace is not sent to its waiting agent tab here (that is for a
    /// user's tap); the saved tab wins.
    public static func decide(saved: LastOpenLocation?, workspaces: [Workspace],
                              macPhase: (String) -> MacDataMachine.Phase) -> Decision {
        guard let saved, saved.rootTab == LastOpenLocation.workspacesTab else { return .nothing }
        guard let workspaceID = saved.workspaceID else { return .showList }
        if let workspace = workspaces.first(where: { $0.id == workspaceID }) {
            let tab = saved.tabID.flatMap { id in workspace.tabs.first { $0.id == id }?.id }
            return .open(workspaceID: workspace.id, tabID: tab)
        }
        guard let macID = saved.macID else { return .showList }
        return isSettled(macPhase(macID)) ? .showList : .wait
    }

    /// Returns the last workspace to mark in the list when it is still known.
    /// A stale id is ignored so a closed workspace never becomes a scroll target.
    public static func listTarget(savedWorkspaceID: String?, workspaces: [Workspace]) -> String? {
        guard let savedWorkspaceID, workspaces.contains(where: { $0.id == savedWorkspaceID }) else { return nil }
        return savedWorkspaceID
    }

    /// The Mac's own list (or its absence) is known: a missing workspace is gone.
    static func isSettled(_ phase: MacDataMachine.Phase) -> Bool {
        switch phase {
        case .live, .empty, .failed, .offline: true
        case .loading, .cached, .idle: false
        }
    }
}

/// Where the last location is kept: `UserDefaults` in the app, memory in tests.
public final class LastOpenMemory: @unchecked Sendable {
    private let lock = NSLock()
    private let read: () -> LastOpenLocation?
    private let write: (LastOpenLocation?) -> Void

    public init(load: @escaping () -> LastOpenLocation?, save: @escaping (LastOpenLocation?) -> Void) {
        read = load
        write = save
    }

    public func load() -> LastOpenLocation? { lock.withLock { read() } }
    public func save(_ location: LastOpenLocation?) { lock.withLock { write(location) } }

    /// JSON under `key` in `defaults`.
    public convenience init(defaults: UserDefaults, key: String = "cmuxMobile.lastOpenLocation") {
        self.init(
            load: { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LastOpenLocation.self, from: $0) } },
            save: { location in
                if let location, let data = try? JSONEncoder().encode(location) {
                    defaults.set(data, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        )
    }

    /// The app's store: survives relaunches.
    public static let standard = LastOpenMemory(defaults: .standard)

    public static func inMemory(_ initial: LastOpenLocation? = nil) -> LastOpenMemory {
        var location = initial
        return LastOpenMemory(load: { location }, save: { location = $0 })
    }
}

/// The workspace most recently visited, kept separately from the full launch location so
/// backing out to the Workspaces list does not erase the workspace to mark there.
public final class LastWorkspaceMemory: @unchecked Sendable {
    private let lock = NSLock()
    private let read: () -> String?
    private let write: (String?) -> Void

    public init(load: @escaping () -> String?, save: @escaping (String?) -> Void) {
        read = load
        write = save
    }

    public func load() -> String? { lock.withLock { read() } }
    public func save(_ workspaceID: String?) { lock.withLock { write(workspaceID) } }

    /// A workspace id under `key` in `defaults`.
    public convenience init(defaults: UserDefaults, key: String = "cmuxMobile.lastVisitedWorkspaceID") {
        self.init(
            load: { defaults.string(forKey: key) },
            save: { workspaceID in
                if let workspaceID, !workspaceID.isEmpty {
                    defaults.set(workspaceID, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        )
    }

    /// The app's store: survives relaunches.
    public static let standard = LastWorkspaceMemory(defaults: .standard)

    public static func inMemory(_ initial: String? = nil) -> LastWorkspaceMemory {
        var workspaceID = initial
        return LastWorkspaceMemory(load: { workspaceID }, save: { workspaceID = $0 })
    }
}
