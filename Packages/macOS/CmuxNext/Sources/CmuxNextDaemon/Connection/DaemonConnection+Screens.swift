import Foundation

// Screen metadata, order, and screen groups (`screen-metadata-v1`,
// `screen-groups-v1`). A daemon without them answers "unknown variant",
// reported as `DaemonError.missingCapabilities`.
extension DaemonConnection {
    @discardableResult
    public func setScreenMetadata(_ screen: ScreenID, color: FieldUpdate<String> = .unchanged,
                                  icon: FieldUpdate<String> = .unchanged) async throws -> ScreenMetadataResult {
        try await requestNew(SetScreenMetadataRequest(screen: screen, color: color, icon: icon))
    }

    @discardableResult
    public func setScreenPinned(_ screen: ScreenID, _ pinned: Bool) async throws -> SetScreenPinnedRequest.Response {
        try await requestNew(SetScreenPinnedRequest(screen: screen, pinned: pinned))
    }

    @discardableResult
    public func moveScreen(_ screen: ScreenID, to index: Int?, workspace: WorkspaceHandle? = nil,
                           newWorkspace: Bool = false) async throws -> MoveScreenRequest.Response {
        try await requestNew(MoveScreenRequest(screen: screen, index: index, workspace: workspace, newWorkspace: newWorkspace ? true : nil))
    }

    /// New screen in `workspace` with `spec` applied in the same commit. The
    /// terminal gets the placement environment like `newTab`.
    @discardableResult
    public func newScreen(in workspace: WorkspaceHandle?, spec: ScreenSpec,
                          options: SpawnOptions = SpawnOptions()) async throws -> NewScreenWithSpecRequest.Response {
        let options = supportsPlacementEnv ? await placed(options) : served(options)
        return try await requestNew(NewScreenWithSpecRequest(workspace: workspace, spec: spec, options: options))
    }

    @discardableResult
    public func createScreenGroup(_ screens: [ScreenID], name: String? = nil, color: String? = nil) async throws -> ScreenGroupResult {
        try await requestNew(CreateScreenGroupRequest(screens: screens, name: name, color: color))
    }

    @discardableResult
    public func updateScreenGroup(_ group: ScreenGroupID, name: String? = nil, color: String? = nil,
                                  collapsed: Bool? = nil) async throws -> ScreenGroupResult {
        try await requestNew(UpdateScreenGroupRequest(group: group, name: name, color: color, collapsed: collapsed))
    }

    @discardableResult
    public func addScreens(_ screens: [ScreenID], toGroup group: ScreenGroupID, index: Int? = nil) async throws -> ScreenGroupResult {
        try await requestNew(AddScreensToScreenGroupRequest(group: group, screens: screens, index: index))
    }

    @discardableResult
    public func removeScreensFromGroup(_ screens: [ScreenID]) async throws -> ScreenGroupResult {
        try await requestNew(RemoveScreensFromScreenGroupRequest(screens: screens))
    }

    @discardableResult
    public func moveScreenGroup(_ group: ScreenGroupID, to index: Int?, workspace: WorkspaceHandle? = nil,
                                newWorkspace: Bool = false) async throws -> ScreenGroupResult {
        try await requestNew(MoveScreenGroupRequest(group: group, index: index, workspace: workspace, newWorkspace: newWorkspace ? true : nil))
    }

    @discardableResult
    public func ungroupScreenGroup(_ group: ScreenGroupID) async throws -> ScreenGroupResult {
        try await requestNew(UngroupScreenGroupRequest(group: group))
    }

    @discardableResult
    public func closeScreenGroup(_ group: ScreenGroupID, endTerminals: Bool? = nil) async throws -> ScreenGroupResult {
        try await requestNew(CloseScreenGroupRequest(group: group, endTerminals: endTerminals))
    }

    @discardableResult
    public func saveScreenGroup(_ group: ScreenGroupID) async throws -> ScreenGroupResult {
        try await requestNew(SaveScreenGroupRequest(group: group))
    }

    @discardableResult
    public func unsaveScreenGroup(_ group: ScreenGroupID) async throws -> ScreenGroupResult {
        try await requestNew(UnsaveScreenGroupRequest(group: group))
    }

    public func listSavedScreenGroups() async throws -> [SavedScreenGroupSnapshot] {
        try await requestNew(ListSavedScreenGroupsRequest()).groups
    }

    public func deleteSavedScreenGroup(_ saved: SavedScreenGroupID) async throws {
        _ = try await requestNew(DeleteSavedScreenGroupRequest(saved: saved))
    }

    @discardableResult
    public func reopenSavedScreenGroup(_ saved: SavedScreenGroupID, in workspace: WorkspaceHandle) async throws -> ScreenGroupResult {
        try await requestNew(ReopenSavedScreenGroupRequest(saved: saved, workspace: workspace))
    }
}
