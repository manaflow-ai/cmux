import CmuxNextDaemon

/// Deadline of an `action.run` whose work is a keyed daemon create that asks
/// again when its reply is late (`ActionDescriptor.waitsForKeyedCreate`,
/// `DaemonConnection.newFrontendBrowserTab`): the retry budget plus one
/// control-plane deadline for the last attempt, plus 1 s for the main-actor
/// work queue and the echo, so the create answers or fails before the request.
enum KeyedCreateDeadline {
    static let request: Duration = DaemonConnection.lateCreateReplyBudget + DaemonConnection.defaultRequestTimeout + .seconds(1)
}
