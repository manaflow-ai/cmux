public import Foundation

/// Rooms and the rest of personal state (`profiles-v1`, home session only;
/// plans/cmux-next/data-model.md 3.3). Every wrapper throws
/// `missingCapabilities` on a daemon without it instead of sending a
/// command it would reject.
extension DaemonConnection {
    public var supportsProfiles: Bool { identity?.supports(DaemonCapabilities.profiles) == true }

    private func requireProfiles() throws {
        guard supportsProfiles else { throw DaemonError.missingCapabilities([DaemonCapabilities.profiles]) }
    }

    public func listPersonal() async throws -> PersonalState {
        try requireProfiles()
        return try await request(ListPersonalRequest())
    }

    // Rooms

    @discardableResult
    public func createProfile(name: String, id: ProfileID = .generate(), color: String? = nil, icon: String? = nil,
                              theme: String? = nil, index: Int? = nil, browserProfileID: BrowserProfileKey? = nil,
                              defaults: ProfileDefaults? = nil) async throws -> ProfileSnapshot {
        try requireProfiles()
        return try await request(CreateProfileRequest(name: name, profile: id, color: color, icon: icon, theme: theme, index: index,
                                                      browserProfileID: browserProfileID, defaults: defaults)).profile
    }

    @discardableResult
    public func updateProfile(_ id: ProfileID, name: String? = nil, color: FieldUpdate<String> = .unchanged,
                              icon: FieldUpdate<String> = .unchanged, theme: FieldUpdate<String> = .unchanged,
                              browserProfileID: FieldUpdate<BrowserProfileKey> = .unchanged,
                              defaults: FieldUpdate<ProfileDefaults> = .unchanged) async throws -> ProfileSnapshot {
        try requireProfiles()
        return try await request(UpdateProfileRequest(profile: id, name: name, color: color, icon: icon, theme: theme,
                                                      browserProfileID: browserProfileID, defaults: defaults)).profile
    }

    public func moveProfile(_ id: ProfileID, to index: Int) async throws {
        try requireProfiles()
        _ = try await request(MoveProfileRequest(profile: id, index: index))
    }

    @discardableResult
    public func deleteProfile(_ id: ProfileID, moveTo: ProfileID? = nil) async throws -> DeleteProfileRequest.Response {
        try requireProfiles()
        return try await request(DeleteProfileRequest(profile: id, moveTo: moveTo))
    }

    public func setFollows(_ id: ProfileID, sessions: [String]) async throws {
        try requireProfiles()
        _ = try await request(SetProfileFollowsRequest(profile: id, sessionIDs: sessions))
    }

    public func pinWorkspace(session: String, key: WorkspaceKey, to room: ProfileID) async throws {
        try requireProfiles()
        _ = try await request(PinWorkspaceRequest(sessionID: session, workspaceKey: key, profile: room))
    }

    public func unpinWorkspace(session: String, key: WorkspaceKey) async throws {
        try requireProfiles()
        _ = try await request(UnpinWorkspaceRequest(sessionID: session, workspaceKey: key))
    }

    // Sessions

    @discardableResult
    public func putSession(_ request: PutSessionRequest) async throws -> PutSessionRequest.Response {
        try requireProfiles()
        return try await self.request(request)
    }

    @discardableResult
    public func forgetSession(_ sessionID: String, force: Bool) async throws -> Bool {
        try requireProfiles()
        return try await request(ForgetSessionRequest(sessionID: sessionID, force: force)).changed
    }

    @discardableResult
    public func importOrganization(_ request: ImportSessionOrganizationRequest) async throws -> Bool {
        try requireProfiles()
        return try await self.request(request).imported
    }

    // Personal groups and organization

    @discardableResult
    public func createPersonalGroup(name: String, id: WorkspaceGroupID? = nil, room: ProfileID, color: String? = nil,
                                    index: Int? = nil) async throws -> WorkspaceGroupSnapshot {
        try requireProfiles()
        return try await request(CreatePersonalGroupRequest(name: name, group: id, profile: room, color: color, index: index)).group
    }

    public func updatePersonalGroup(_ id: WorkspaceGroupID, name: String? = nil, color: FieldUpdate<String> = .unchanged,
                                    collapsed: Bool? = nil, room: ProfileID? = nil) async throws {
        try requireProfiles()
        _ = try await request(UpdatePersonalGroupRequest(group: id, name: name, color: color, collapsed: collapsed, profile: room))
    }

    public func deletePersonalGroup(_ id: WorkspaceGroupID) async throws {
        try requireProfiles()
        _ = try await request(DeletePersonalGroupRequest(group: id))
    }

    public func movePersonalGroup(_ id: WorkspaceGroupID, to index: Int) async throws {
        try requireProfiles()
        _ = try await request(MovePersonalGroupRequest(group: id, index: index))
    }

    public func setPersonalWorkspace(_ request: SetPersonalWorkspaceRequest) async throws {
        try requireProfiles()
        _ = try await self.request(request)
    }
}
