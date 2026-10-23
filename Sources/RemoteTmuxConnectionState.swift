import Foundation

/// What a failed reconnect attempt means, decided from the attempt's own output.
///
/// Extracted as a pure function (``RemoteTmuxReconnectDisposition/classify(stderr:preControlOutput:decoding:)``)
/// because the three-way decision is the whole behavior worth testing: driving it
/// through a real `Process` would test ssh, not the decision.
enum RemoteTmuxReconnectDisposition: Sendable, Equatable {
    /// The session or server is gone. The connection ends and observers see `%exit`.
    case sessionGone
    /// The host wants interactive authentication. A pipe-backed reconnect runs
    /// `BatchMode=yes` with no controlling tty, so NO number of retries can satisfy a
    /// password / MFA / security-key touch: retrying is futile and freezes the mirror
    /// with nothing on screen to explain why. The user is handed a login instead.
    ///
    /// This also covers a `ProxyCommand` that closes the transport silently under
    /// BatchMode, which is the same situation without an explicit auth error string.
    case authRequired
    /// Anything else (unreachable, refused, a dropped hop). Retry with backoff.
    case transient

    /// Classifies a failed reconnect attempt.
    ///
    /// Order matters: a gone session wins over an auth failure, because a host can
    /// report both (the session vanished *and* the re-attach could not authenticate)
    /// and ending is the correct, non-recoverable outcome.
    static func classify(
        stderr: String,
        preControlOutput: String,
        decoding: RemoteTmuxControlMessageDecoding = RemoteTmuxControlMessageDecoding()
    ) -> RemoteTmuxReconnectDisposition {
        if decoding.stderrIndicatesSessionGone(stderr)
            || decoding.controlOutputIndicatesSessionGone(preControlOutput) {
            return .sessionGone
        }
        if RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
            return .authRequired
        }
        // A transport that authenticates itself reports no failure: it prints a prompt and waits.
        // With pipes instead of a terminal that prompt lands here, in the bytes before control mode,
        // and the stream just sits there. Reading it as transient meant the attach failed with
        // nothing to explain it — measured through a corporate ssh broker, whose passcode prompt
        // produced no stderr at all. An unanswered prompt is exactly the case a login can fix.
        if RemoteTmuxSSHTransport.indicatesUnansweredCredentialPrompt(preControlOutput) {
            return .authRequired
        }
        return .transient
    }
}

/// Bookkeeping for "at most one login workspace per host", extracted so the rule is a
/// testable object rather than a convention spread across a callback and a wait loop.
///
/// Two things went wrong when this was an ad-hoc dictionary, and both are encoded here:
///
/// - The slot has to be reserved *before* the workspace is created. Creating a workspace
///   is not instantaneous, and several sessions on one host report auth-required in the
///   same turn; with the record written afterwards, every one of them passed the "is a
///   login already open?" check and opened its own tab.
/// - A *resume attempt* must not release the slot. A resume can fail authentication all
///   over again, and releasing on the attempt meant each failure opened another tab. The
///   slot is released only when the connection actually reaches `.connected`, when the
///   workspace is gone, or when creating it failed.
struct RemoteTmuxLoginOffers: Sendable, Equatable {
    /// Why a caller should or should not open a login workspace.
    enum Decision: Sendable, Equatable {
        /// This caller owns the slot for `generation` and must open the workspace, then
        /// call ``recordOpened(host:workspace:generation:)`` or ``abandon(host:generation:)``.
        case present(Generation)
        /// Another caller is opening one, or an open one is still on screen.
        case alreadyOffered
        /// The user dismissed the offer for this outage, so do not open another.
        case declined
    }

    /// Identifies one offer. A waiter carries the generation it started for, so a waiter
    /// that suspends across an `await` cannot release an offer that has since been
    /// replaced by a newer one.
    struct Generation: Sendable, Equatable {
        fileprivate let value: UInt64
    }

    private enum Slot: Equatable {
        /// Reserved by a caller that has not finished creating the workspace yet.
        case claimed(Generation)
        /// A workspace that exists (until `isOpen` says otherwise).
        case opened(UUID, Generation)
        /// The user closed the login without signing in. No further login is offered for
        /// this outage; the connection keeps retrying quietly and a reconnect clears this.
        case declined(Generation)

        var generation: Generation {
            switch self {
            case .claimed(let g), .opened(_, let g), .declined(let g): return g
            }
        }
    }

    private var slots: [String: Slot] = [:]
    private var nextGeneration: UInt64 = 0

    init() {}

    /// Reserves the right to present a login for `host`, or reports that one is already
    /// offered. `isOpen` answers whether a previously opened workspace still exists, so a
    /// dismissed login does not suppress the next offer forever.
    mutating func claim(host: String, isOpen: (UUID) -> Bool) -> Decision {
        switch slots[host] {
        case .claimed:
            return .alreadyOffered
        case .declined:
            // The user said no. Re-offering here is what made the close button useless: the
            // tab reappeared immediately because the retry that followed failed the same way.
            return .declined
        case .opened(let workspace, _) where isOpen(workspace):
            return .alreadyOffered
        case .opened, nil:
            nextGeneration += 1
            let generation = Generation(value: nextGeneration)
            slots[host] = .claimed(generation)
            return .present(generation)
        }
    }

    /// Records the workspace a successful ``claim(host:isOpen:)`` opened. Ignored if a newer
    /// offer has replaced this one.
    mutating func recordOpened(host: String, workspace: UUID, generation: Generation) {
        guard slots[host]?.generation == generation else { return }
        slots[host] = .opened(workspace, generation)
    }

    /// Releases an offer this caller still owns. A stale caller is ignored, so a waiter
    /// that suspended across an `await` cannot discard a newer offer.
    mutating func abandon(host: String, generation: Generation) {
        guard slots[host]?.generation == generation else { return }
        slots[host] = nil
    }

    /// Records that the user closed the login without signing in.
    ///
    /// The connection still goes back to retrying, so a host that starts accepting
    /// authentication again recovers on its own. What stops is the *offering*: without this
    /// the retry fails the same way, a fresh login opens, and the close button appears not
    /// to work. A successful reconnect clears it, so the next real outage offers again.
    mutating func noteDeclined(host: String, generation: Generation) {
        guard slots[host]?.generation == generation else { return }
        slots[host] = .declined(generation)
    }

    /// Whether the user has dismissed this host's login for the current outage.
    func isDeclined(host: String) -> Bool {
        if case .declined = slots[host] { return true }
        return false
    }

    /// Releases the slot because the host is connected again, so the next outage starts
    /// from a clean state.
    mutating func noteConnected(host: String) {
        slots[host] = nil
    }

    /// The workspace currently offered for `host`, with the generation that owns it.
    func openedWorkspace(host: String) -> (workspace: UUID, generation: Generation)? {
        if case .opened(let workspace, let generation) = slots[host] {
            return (workspace, generation)
        }
        return nil
    }

    /// Whether `host` has any offer outstanding (claimed or opened).
    func hasOffer(host: String) -> Bool { slots[host] != nil }

    /// The host whose open login is `workspace`, if any.
    ///
    /// The close path knows only which workspace the user closed, so resolving it back to a host
    /// is what lets a closed tab be treated as declining that host's login.
    func host(forOpenedWorkspace workspace: UUID) -> String? {
        for (host, slot) in slots {
            if case .opened(let opened, _) = slot, opened == workspace { return host }
        }
        return nil
    }
}

enum RemoteTmuxConnectionState: Sendable, Equatable {
    /// The initial connection is being established before the first control-mode
    /// `%enter`.
    case connecting

    /// Live: control mode is up and streaming.
    case connected

    /// The transport dropped; retrying with backoff while the mirror stays frozen.
    case reconnecting

    /// Permanently over: genuine `%exit`, session gone, or deliberate stop.
    case ended
}
