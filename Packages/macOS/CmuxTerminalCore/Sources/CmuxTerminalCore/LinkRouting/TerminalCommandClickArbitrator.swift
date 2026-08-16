import Foundation

/// The in-flight state of a hard-wrapped-path command-click candidate for
/// one left-mouse gesture, from `prepareCommandClickContext` through the
/// eventual release.
///
/// `GhosttyNSView` owns exactly one `pendingCommandClickContext` value per
/// gesture; this type carries no mutable state of its own, which is what
/// lets `TerminalCommandClickArbitrator`'s transitions be unit tested
/// without a live Ghostty surface.
public enum CommandClickContextState: Equatable {
    /// A wrapped-path candidate was prepared before Ghostty's release call;
    /// no native `open_url` callback claimed it (yet).
    case prepared(TerminalWrappedPathResolution)
    /// Ghostty's `open_url` callback fired for an explicit-scheme URL (or
    /// found no matching prepared candidate); the callback already routed
    /// it through `TerminalLinkOpenCoordinator`.
    case nativePassthrough
    /// Ghostty's `open_url` callback fired for a schemeless URL that
    /// exactly matched the prepared candidate's token; the callback claimed
    /// it (suppressing Ghostty's own opener) and deferred the actual open
    /// to the shared release-time helper.
    case overridePending(TerminalWrappedPathResolution)
}

/// Pure decision logic coordinating a hard-wrapped-path command-click
/// candidate against Ghostty's own `open_url` callback and the eventual
/// release, isolated from `GhosttyNSView` so every transition can be
/// exercised without a live Ghostty surface.
public enum TerminalCommandClickArbitrator {
    /// The effect the release handler should perform for a gesture's final
    /// state.
    public enum ReleaseAction: Equatable {
        /// No candidate claimed the native callback; fall through to the
        /// existing word-under-cursor release logic.
        case fallThroughToWordUnderCursor
        /// Ghostty already handled the click; finish without opening another
        /// path or invoking the word-under-cursor fallback.
        case finishWithoutFallback
        /// Open this resolved wrapped-path candidate through the shared
        /// fallback path.
        case openWrappedCandidate(TerminalWrappedPathResolution)
    }

    /// Applies one `GHOSTTY_ACTION_OPEN_URL` observation to the in-flight
    /// state.
    ///
    /// An explicit scheme (including `file:`) always passes through first,
    /// since a wrapped-path candidate is a bare absolute path and never
    /// needs to compete with a scheme-qualified link. Otherwise, an exact
    /// match against any of a `.prepared` candidate's finite
    /// `nativeMatchKeys` claims the URL; everything else passes through.
    /// Substring, prefix/suffix, and case-folded matches never claim —
    /// mismatch is never speculatively upgraded to a match.
    ///
    /// - Parameters:
    ///   - currentState: The state captured by `prepareCommandClickContext`
    ///     before Ghostty's release call.
    ///   - hasExplicitScheme: Whether the callback's raw URL string parses
    ///     with a scheme.
    ///   - matchKey: The callback's raw URL string, normalized the same way
    ///     as each of `TerminalWrappedPathResolution.nativeMatchKeys`.
    /// - Returns: The next state to hold, and whether the callback should
    ///   claim the URL (return `true`, suppressing Ghostty's own
    ///   `internal_os.open`) instead of passing through to
    ///   `TerminalLinkOpenCoordinator`.
    public static func openURLCallbackResult(
        currentState: CommandClickContextState?,
        hasExplicitScheme: Bool,
        matchKey: String
    ) -> (nextState: CommandClickContextState, shouldClaim: Bool) {
        if hasExplicitScheme {
            return (.nativePassthrough, false)
        }
        if case .prepared(let candidate) = currentState, candidate.nativeMatchKeys.contains(matchKey) {
            return (.overridePending(candidate), true)
        }
        return (.nativePassthrough, false)
    }

    /// The action the release handler should perform for the final state
    /// captured immediately after Ghostty's release call returns.
    ///
    /// `.overridePending` and `.prepared` with `ghosttyConsumed == false`
    /// both open the same candidate through the same helper, so a click on
    /// either wrapped row ends up opening exactly once under the same
    /// policy. `.nativePassthrough` is distinct from a missing state:
    /// Ghostty already handled that click and the host must not fall through
    /// to a second word-under-cursor open.
    ///
    /// - Parameters:
    ///   - finalState: The state after Ghostty's release call and any
    ///     `open_url` callback it triggered.
    ///   - ghosttyConsumed: Whether Ghostty's release call reported the
    ///     click as consumed (it resolved a native link target itself).
    public static func releaseAction(
        finalState: CommandClickContextState?,
        ghosttyConsumed: Bool
    ) -> ReleaseAction {
        switch finalState {
        case .none:
            return .fallThroughToWordUnderCursor
        case .nativePassthrough:
            return .finishWithoutFallback
        case .overridePending(let candidate):
            return .openWrappedCandidate(candidate)
        case .prepared(let candidate):
            return ghosttyConsumed ? .finishWithoutFallback : .openWrappedCandidate(candidate)
        }
    }
}
