/// A step of a hosted-browser sign-in that a host can count, for example in
/// product analytics. It never carries the callback URL, tokens, state or
/// error text.
public enum HostBrowserSignInEvent: Equatable, Sendable {
    /// A browser attempt opened its sign-in window.
    case attemptStarted(HostBrowserSignInAttempt)
    /// An auth callback URL was handed to sign-in completion. Its payload,
    /// state and tokens are not validated yet, so this is receipt only, not
    /// proof that the browser or provider sign-in succeeded. `attempt` is the
    /// attempt that issued the state the callback carried, which may be an
    /// earlier, replaced attempt; nil for a stateless callback (the embedded
    /// browser's handoff or an approved unsolicited one), which no attempt
    /// issued.
    case callbackReceived(HostBrowserCallbackSource, attempt: HostBrowserSignInAttempt?)
    /// That callback finished signing the app in.
    case signInCompleted(attempt: HostBrowserSignInAttempt?)
    /// That callback did not sign the app in and set ``HostBrowserSignInFlow/lastFailure``.
    /// A callback dropped because a sign-out or a newer attempt raced it sets
    /// no failure and reports nothing.
    case callbackFailed(attempt: HostBrowserSignInAttempt?)
    /// A callback was refused before completion (a state no live attempt
    /// matches, or a malformed payload) and set ``HostBrowserSignInFlow/lastFailure``.
    /// `attempt` is the attempt that issued the callback's state, or nil when
    /// no tracked attempt did; such a refusal belongs to no attempt.
    case callbackRefused(attempt: HostBrowserSignInAttempt?)
    /// The user closed the attempt's sign-in window and that ended the
    /// attempt. A callback carrying its state can still complete it later.
    case windowClosedByUser(HostBrowserSignInAttempt)
}

/// One browser sign-in attempt of this flow, for joining its events. An
/// in-memory counter, unrelated to the callback state or any account.
public struct HostBrowserSignInAttempt: Hashable, Sendable {
    let rawValue: UInt64

    init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Where an auth callback came from.
public enum HostBrowserCallbackSource: Equatable, Sendable {
    /// The in-app sign-in window returned it.
    case signInWindow
    /// LaunchServices delivered it, for example from the default browser.
    case external
    /// The embedded browser's own after-sign-in handoff.
    case embeddedBrowser
}
