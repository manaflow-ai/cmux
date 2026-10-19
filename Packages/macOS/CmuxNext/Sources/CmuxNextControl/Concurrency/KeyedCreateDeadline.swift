import CmuxNextActions
import CmuxNextDaemon

/// Deadline of an `action.run` whose work is a keyed daemon create that asks
/// again when its reply is late (`ActionDescriptor.waitsForKeyedCreate`,
/// `NewFrontendBrowserTabRequest.send(on:)`): the retry budget plus one
/// control-plane deadline for the last attempt, plus 1 s for the main-actor
/// work queue and the echo, so the create answers or fails before the request.
enum KeyedCreateDeadline {
    static let request: Duration = NewFrontendBrowserTabRequest.lateReplyBudget + DaemonConnection.defaultRequestTimeout + .seconds(1)

    /// `action.run`'s limit for `action` (nil: the method's own deadline).
    /// `wait` is the request's `wait` param (nil: the default, which waits).
    static func limit(for action: ControlActionInfo, wait: Bool?) -> Duration? {
        // A network action the caller awaits (Connect to CodeRouter).
        if wait == true, action.waitsForResult { return ActionDescriptor.resultDeadline }
        // A keyed create that asks again while its reply is late (a busy disk).
        if wait ?? true, action.waitsForKeyedCreate { return request }
        return nil
    }
}
