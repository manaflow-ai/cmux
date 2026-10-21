import CmuxNextActions
import CmuxNextDaemon

/// `action.run`'s limit for an action whose work outlasts the control-plane
/// deadline by design (nil: the method's own deadline).
enum ActionRunLimit {
    /// A keyed daemon create that asks again when its reply is late
    /// (`ActionDescriptor.waitsForKeyedCreate`, `NewFrontendBrowserTabRequest.send(on:)`):
    /// the retry budget plus one control-plane deadline for the last attempt,
    /// plus 1 s for the main-actor work queue and the echo, so the create
    /// answers or fails before the request.
    static let keyedCreate: Duration = NewFrontendBrowserTabRequest.lateReplyBudget + DaemonConnection.defaultRequestTimeout + .seconds(1)

    /// `wait` is the request's `wait` param (nil: the default, which waits).
    static func limit(for action: ControlActionInfo, wait: Bool?) -> Duration? {
        if wait == true {
            // A run that waits for a person (an agent's cookie import consent) gets the longest limit.
            if action.waitsForPerson { return ActionDescriptor.personDeadline }
            // A network action the caller awaits (Connect to CodeRouter).
            if action.waitsForResult { return ActionDescriptor.resultDeadline }
        }
        // A keyed create that asks again while its reply is late (a busy disk).
        if wait ?? true, action.waitsForKeyedCreate { return keyedCreate }
        return nil
    }
}
