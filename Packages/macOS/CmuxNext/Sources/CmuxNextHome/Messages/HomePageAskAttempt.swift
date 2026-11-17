public import CmuxNextPages
public import CmuxNextSettings

/// One try of a host-to-page call (`HomeMessagesPage.ask`). Only a page that is not ready yet (no
/// handler: it is still loading or reconnecting, or its link is down) is asked again; a page that
/// answered, even with a refusal, is not. A try that times out may have run in the page, so a retry
/// carries the same request id and the page runs each request once (pageCommands.ts `once`).
public enum HomePageAskAttempt: Sendable, Equatable {
    case answered(JSONValue)
    /// No handler or no link yet: ask again.
    case notReady
    /// The page took the call and refused it: asking again would run it again.
    case refused

    /// What a failed call means.
    public init(_ error: any Error) {
        let code = (error as? PageError)?.code
        self = code == PageError.unknownOp("").code || code == PageError.closed.code ? .notReady : .refused
    }
}
