import CmuxNextIPC
import Foundation

/// Stash (`stash-v1`; cmux-tui/spec/resource-operations-v2.json `stash.*`):
/// browser tabs closed into one named group, restored or deleted later, and
/// OneTab exports imported as groups. Callers check
/// `DaemonCapability.stash` first.
extension StateResourceClient {
    /// Where `stash.restore` reopens pages.
    public enum StashTarget: String, Sendable {
        /// Each page in its pane at its index when that pane is live, else nearby.
        case here
        /// Every page, in order, in one new workspace named after the stash.
        case newWorkspace = "new_workspace"
    }

    /// What `stash.create` closed.
    public struct StashCreated: Decodable, Sendable, Equatable {
        public var stashID: String
        /// The pages it closed (empty for whole workspaces).
        public var tabIDs: [ResourceID]

        enum CodingKeys: String, CodingKey {
            case stashID = "stash_id"
            case tabIDs = "tab_ids"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stashID = try c.decode(String.self, forKey: .stashID)
            tabIDs = try c.decodeIfPresent([ResourceID].self, forKey: .tabIDs) ?? []
        }
    }

    /// What `stash.import` kept: pages imported, and pages skipped (not http(s), or repeated).
    public struct StashImported: Decodable, Sendable, Equatable {
        public var importedTabs: Int
        public var skippedTabs: Int

        enum CodingKeys: String, CodingKey {
            case importedTabs = "imported_tabs"
            case skippedTabs = "skipped_tabs"
        }
    }

    /// One page of an imported group (`StashImportTab`).
    public struct StashImportPage: Sendable, Equatable {
        public var url: String
        public var title: String?

        public init(url: String, title: String?) {
            self.url = url
            self.title = title
        }
    }

    /// One imported group (`StashImportGroup`): one stash.
    public struct StashImportGroup: Sendable, Equatable {
        public var name: String?
        public var pages: [StashImportPage]

        public init(name: String?, pages: [StashImportPage]) {
            self.name = name
            self.pages = pages
        }
    }

    /// Closes browser tabs `tabs` into one stash named after the first one's workspace.
    @discardableResult
    public func stashTabs(_ tabs: [ResourceID]) async throws -> StashCreated {
        try await stateMutation(V2StashCreateRequest(tabs: tabs.map { V2TabID(rawValue: $0.rawValue) }), as: StashCreated.self)
    }

    /// Closes workspace `workspace`'s unpinned web pages into one stash; its other tabs stay.
    @discardableResult
    public func stashWorkspace(_ workspace: ResourceID) async throws -> StashCreated {
        try await stateMutation(V2StashCreateRequest(workspace: V2WorkspaceID(rawValue: workspace.rawValue)), as: StashCreated.self)
    }

    /// Closes workspaces `workspaces` whole (every tab, ending their terminals) into one stash
    /// named `name` (else the workspace's name for one, none for several). Needs
    /// `DaemonCapability.stashWorkspaces`.
    @discardableResult
    public func stashWorkspaces(_ workspaces: [ResourceID], name: String? = nil) async throws -> StashCreated {
        let request = V2StashCreateRequest(name: name, workspaces: workspaces.map { V2WorkspaceID(rawValue: $0.rawValue) })
        return try await stateMutation(request, as: StashCreated.self)
    }

    /// Every stash, newest first (`stash.list`).
    public func stashes() async throws -> [StashRecord] {
        try await stateRead(V2StashListRequest(), as: [StashRecord].self)
    }

    /// Reopens stash `id`'s members named `members` (member ids; every member for nil); they
    /// leave the stash. `here` puts a member whose own pane is gone in `pane` (the pane the user
    /// acted from). An id the stash no longer holds refuses the whole request.
    @discardableResult
    public func restoreStash(_ id: String, members: [String]? = nil, target: StashTarget = .here,
                             pane: ResourceID? = nil) async throws -> ReopenedItem {
        try await stateMutation(Self.stashRestoreRequest(id, members: members, target: target, pane: pane),
                                as: ReopenedItem.self)
    }

    static func stashRestoreRequest(_ id: String, members: [String]?, target: StashTarget,
                                    pane: ResourceID?) -> V2StashRestoreRequest {
        V2StashRestoreRequest(members: members, pane: pane.map { V2PaneID(rawValue: $0.rawValue) }, stash: id,
                              target: V2StashRestoreRequest.Target(rawValue: target.rawValue))
    }

    /// Deletes stash `id`'s members named `members` (member ids), or the whole stash for nil.
    public func deleteStash(_ id: String, members: [String]? = nil) async throws {
        try await stateMutation(V2StashDeleteRequest(members: members, stash: id))
    }

    /// Imports OneTab groups as stashes whose pages reopen in `engine` (`webkit`, `cef`).
    @discardableResult
    public func importOneTab(_ groups: [StashImportGroup], engine: String?) async throws -> StashImported {
        try await stateMutation(Self.oneTabImportRequest(groups, engine: engine), as: StashImported.self)
    }

    static func oneTabImportRequest(_ groups: [StashImportGroup], engine: String?) -> V2StashImportRequest {
        let wire = groups.map { group in
            V2StashImportGroup(name: group.name, tabs: group.pages.map { V2StashImportTab(title: $0.title, url: $0.url) })
        }
        return V2StashImportRequest(engine: engine.map { V2StashImportRequest.Engine(rawValue: $0) }, groups: wire,
                                    source: .onetab)
    }
}
