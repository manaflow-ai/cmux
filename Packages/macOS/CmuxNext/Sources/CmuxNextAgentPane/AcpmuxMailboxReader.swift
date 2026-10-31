public import CmuxNextDaemon

/// Reads one acpmux mailbox alias for as long as the calling task runs, off
/// the main actor: each page goes to `deliver`, and a failed wait is retried
/// through ``RetryPacer`` and ``RetryWake`` (plans/cmux-next/idle-wakeups.md),
/// the shared retry path of every daemon client.
///
/// The reader does not start acpmux. While acpmux's socket is missing it waits
/// for the socket to appear (a vnode event, also when the socket's folder does
/// not exist yet) or for ``RetryWake/fire()``, and arms no timer. While the
/// socket exists but refuses (a crashed acpmux's stale socket, a handoff) it
/// retries a bounded number of times spaced by the backoff, then waits for the
/// socket to be replaced or an event; a socket that replaced it gets timed
/// retries of its own (``RetryPacer/failed(at:)``). A page resets the pacing.
/// The socket is watched only while a failed wait is retried: a reader that
/// reads, or that ended, keeps no watch.
///
/// A main-actor owner runs it through ``AcpmuxMailboxSubscription``, which
/// drops a page that arrives after the reader was replaced or stopped:
///
/// ```swift
/// let reader = AcpmuxMailboxReader(socketPath: environment.socketPath, recipient: "reports:\(person)", wake: wake)
/// reports.start(reader) { [weak self] page in self?.apply(page) }
/// ```
public nonisolated struct AcpmuxMailboxReader: Sendable {
    /// One mailbox wait for the rows after a cursor.
    typealias MailboxWait = @Sendable (_ after: UInt64) async throws -> AcpmuxMailboxPage

    private let socketPath: String
    private let wake: RetryWake
    private let clock: any Clock<Duration>
    private let policy: RetryPolicy
    private let mailboxWait: MailboxWait

    /// - Parameters:
    ///   - socketPath: acpmux's socket (``AcpmuxEnvironment/socketPath``).
    ///   - recipient: The alias read (`reports:<person>`).
    ///   - client: The mailbox client.
    ///   - wake: Wakes a waiting retry; the owner fires it on app activation, so a reader that
    ///     spent its timed retries still tries again then.
    ///   - clock: The retry timer's clock.
    public init(socketPath: String, recipient: String, client: AcpmuxMailboxClient = AcpmuxMailboxClient(),
                wake: RetryWake, clock: any Clock<Duration> = ContinuousClock()) {
        // A first connect's pacing: 250 ms growing to 30 s, 10 timed attempts, then events only.
        self.init(socketPath: socketPath, wake: wake, clock: clock, policy: .firstConnect) { after in
            // concurrency-allow: an async acpmux mailbox request (awaits the socket reply), not a semaphore/group wait; run() is @concurrent, off main
            try await client.wait(socketPath: socketPath, recipient: recipient, after: after)
        }
    }

    /// Tests pass the mailbox wait.
    init(socketPath: String, wake: RetryWake, clock: any Clock<Duration>, policy: RetryPolicy,
         mailboxWait: @escaping MailboxWait) {
        self.socketPath = socketPath
        self.wake = wake
        self.clock = clock
        self.policy = policy
        self.mailboxWait = mailboxWait
    }

    /// Reads pages from the start of the alias until the task is cancelled.
    ///
    /// - Parameter deliver: Gets each page on the main actor.
    @concurrent
    public func run(deliver: @MainActor @Sendable (AcpmuxMailboxPage) -> Void) async {
        defer { wake.unwatch() }
        var pacer = RetryPacer(policy)
        var cursor: UInt64 = 0
        // wakeup-allow: each pass is one event-driven mailbox wait (acpmux answers on new mail or its 30 s wait end); a failure waits in RetryPacer
        while !Task.isCancelled {
            do {
                let page = try await mailboxWait(cursor)
                pacer.reset()
                // A reader that reads keeps no watch: the next failure arms it again.
                wake.unwatch()
                cursor = Self.cursor(after: page, from: cursor)
                guard !Task.isCancelled else { return }
                await deliver(page)
            } catch is CancellationError {
                return
            } catch {
                // Armed only while retrying; the rebaseline below takes the socket as it is now.
                wake.watch(file: socketPath)
                // concurrency-allow: an async wait for the socket to change or the paced retry, not a blocking wait
                guard await pacer.waitForPeerAfterFailure(wake: wake, clock: clock) else { return }
            }
        }
    }

    /// The cursor after `page`: its next cursor, else its last row, never back.
    static func cursor(after page: AcpmuxMailboxPage, from cursor: UInt64) -> UInt64 {
        if let next = page.nextCursor { return max(cursor, next) }
        if let last = page.messages.last { return max(cursor, last.seq) }
        return cursor
    }
}
