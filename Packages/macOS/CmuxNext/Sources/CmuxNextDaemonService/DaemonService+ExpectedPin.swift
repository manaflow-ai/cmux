public import CmuxNextDaemon

extension DaemonService {
    /// On this home daemon, before a workspace create that pins workspace `key` of `session` to `room` first
    /// (`pinWorkspaceBeforeCreate`): the workspace reads as in `room` from the press (`PersonalStore.expectedPins`), not
    /// in `default` until the pin's refetch lands. Nothing when no pin will be sent (no connection, session or room).
    public func expectPinBeforeCreate(session: String?, key: WorkspaceKey, room: ProfileID) {
        guard connection != nil, let session, let room = store.profile(room)?.id else { return }
        store.personal.expectPin(session: session, key: key, room: room)
    }
}
