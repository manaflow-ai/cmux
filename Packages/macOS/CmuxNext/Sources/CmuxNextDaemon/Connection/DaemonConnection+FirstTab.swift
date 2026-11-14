import Foundation

extension NewConversationTabRequest {
    /// A new workspace's first agent tab on `record` in `workspace` (Cmd-N's New Tab page), keyed by `mutationID` and
    /// echoing `transaction` on the event that adds it.
    public static func firstAgentTab(_ record: AgentSessionRef, in workspace: WorkspaceHandle, origin: String, mutationID: String,
                                     transaction: ClientTransactionID) -> NewConversationTabRequest {
        var request = NewConversationTabRequest(agentSession: record, workspace: workspace, origin: origin, mutationID: mutationID)
        request.transaction = transaction
        return request
    }
}

extension NewConversationTabRequest.Response {
    /// The tab's key in the app: its resource id, else `surface:<surface>`.
    public var tabKey: String { tabResourceID?.rawValue ?? "surface:\(surface.rawValue)" }
}

extension DaemonConnection {
    /// Sends `request` (a new workspace's first tab), asking again on a late reply until `giveUp`: one mutation id for
    /// every send, so a tab the daemon made after the deadline replays.
    public func newFirstTab(_ request: NewConversationTabRequest, until giveUp: ContinuousClock.Instant) async throws -> NewConversationTabRequest.Response {
        try await Self.retryingLateReplies(NewConversationTabRequest.command, until: giveUp) { try await self.request(request) }
    }

    /// Pins workspace `key` of session `session` to room `room` in this home connection before the workspace's create
    /// (``PinWorkspaceRequest/beforeCreate(session:key:room:)``), asking again on a late reply until `giveUp` (nil: the
    /// default budget), so no snapshot shows it in another room. False when there was nothing to pin.
    @discardableResult
    public func pinWorkspaceBeforeCreate(session: String?, key: WorkspaceKey, to room: ProfileID?, until giveUp: ContinuousClock.Instant? = nil) async throws -> Bool {
        guard let pin = PinWorkspaceRequest.beforeCreate(session: session, key: key, room: room) else { return false }
        try await Self.retryingLateReplies(PinWorkspaceRequest.command, until: giveUp) { try await self.pinWorkspace(session: pin.sessionID, key: key, to: pin.profile) }
        return true
    }
}

extension PinWorkspaceRequest {
    /// A new workspace's pin to its room before its create: none when it is born in no room or its daemon has no
    /// session id yet (the workspace then stays where its daemon lists it).
    public static func beforeCreate(session: String?, key: WorkspaceKey, room: ProfileID?) -> PinWorkspaceRequest? {
        guard let session, let room else { return nil }
        return PinWorkspaceRequest(sessionID: session, workspaceKey: key, profile: room)
    }
}
