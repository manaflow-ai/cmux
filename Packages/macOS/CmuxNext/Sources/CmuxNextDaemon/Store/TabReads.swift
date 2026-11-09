public import CmuxNextWakeups
import Foundation

/// A read the person made on a tab (its unread notification, its Mark as Unread, an agent's mark), sent until the
/// tab's daemon answers it. The read shows at once (``TabModel/expectNotificationRead()`` and its kin) and stays while
/// the daemon is down, reconnecting or still restoring (Leo, 2026-11-09: "the other thing is that for some reason the
/// dot isn't disappearing in my case... but i guess the current nightly still hasn't fixed/restarted the service?"). A
/// daemon that is not connected, drops the connection or misses its deadline has not refused the read
/// (``PersonalWriteLedger/isUnanswered(_:)``): the write goes again, spaced by ``Backoff`` (0.25 s doubling to 5 s),
/// so it reaches the daemon within one spacing of its coming back. Only the daemon's refusal rolls the read back.
///
/// Each write stops at its answer, at a refusal, or once its read no longer stands (`stands`): the daemon's record
/// settled it (read, or a newer notification the person has not seen), the person changed it, or its daemon was
/// torn down. A read also belongs to the daemon it was made on (`current`): a daemon of another generation numbers
/// its notifications and surfaces anew, so the same number there may be a notification the person never saw, and a
/// removed tab's handle may be another tab's. Once `current` fails the write ends and the read rolls back: the new
/// record shows what it holds.
@MainActor public final class TabReads {
    /// Waits out one spacing between tries; tests replace it.
    public var pause: @MainActor (inout Backoff) async -> Void = { backoff in
        // concurrency-allow: an async Backoff wait suspends this task; it never blocks the main thread
        try? await backoff.wait(owner: "tab read retry")
    }

    /// The notification reads being sent (tab id and notification): a read of one of them stands for this one too.
    /// A write that ended (answered, refused, or no longer standing) leaves it, so the next read sends again.
    private var sending: Set<String> = []

    public init() {}

    /// Sends `attempt` until it is answered while `stands()` holds; `refused` gets the daemon's refusal, `answered`
    /// its reply. Returns the task, which ends at the answer, the refusal or the read no longer standing.
    @discardableResult
    public func send<T: Sendable>(stands: @escaping @MainActor () -> Bool,
                                  current: @escaping @MainActor () -> Bool = { true },
                                  refused: @escaping @MainActor (any Error) -> Void,
                                  answered: @escaping @MainActor (T) -> Void = { _ in },
                                  ended: @escaping @MainActor () -> Void = {},
                                  _ attempt: @escaping @MainActor () async throws -> T) -> Task<Void, Never> {
        let pause = pause
        // task-owner: one read the person made, sent again while unanswered; ends on its answer, a refusal or the read
        // no longer standing (`stands`)
        return Task { @MainActor in
            defer { ended() }
            var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(5), jitter: 0.1)
            while stands(), !Task.isCancelled {
                guard current() else { return refused(CancellationError()) }
                do {
                    let reply = try await attempt()
                    return answered(reply)
                } catch where PersonalWriteLedger.isUnanswered(error) {
                    await pause(&backoff)
                } catch {
                    if stands() { refused(error) }
                    return
                }
            }
        }
    }

    /// Reads `tab`'s unread notification: it shows read at once, and `ack` (`ack-tab-notifications` for the surface it
    /// is given) goes until answered while `alive` holds. While the daemon is down or restoring the read stays; only
    /// its refusal shows the dot again. The tree's echo settles it: read, or a newer notification, which shows (the
    /// person has not seen it) and ends this write. Nil when the tab had no unread notification to read.
    @discardableResult
    public func readNotification<T: Sendable>(of tab: TabModel, alive: @escaping @MainActor () -> Bool = { true },
                                              current: @escaping @MainActor () -> Bool = { true },
                                              answered: @escaping @MainActor (T) -> Void = { _ in },
                                              _ ack: @escaping @MainActor (SurfaceID) async throws -> T) -> Task<Void, Never>? {
        tab.expectNotificationRead()
        guard let reading = tab.readingNotification else { return nil }
        // A read of this notification already on its way stands for this one too.
        let key = "\(tab.id)#\(reading.rawValue)"
        guard sending.insert(key).inserted else { return nil }
        return send(stands: { tab.readingNotification == reading && alive() }, current: current,
                    refused: { _ in tab.dropExpectedNotificationRead() }, answered: answered,
                    ended: { _ = key }) {
            // The tab's surface as it is at this try: a daemon that came back may number it anew.
            try await ack(tab.surface)
        }
    }

    /// Clears `tab`'s Mark as Unread the same way: shown read at once, `write` goes until answered, and only the
    /// daemon's refusal rolls it back. The record's echo of the clear ends it.
    @discardableResult
    public func clearMarkedUnread(of tab: TabModel, alive: @escaping @MainActor () -> Bool = { true },
                                  current: @escaping @MainActor () -> Bool = { true },
                                  _ write: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        tab.expectMarkedUnread(false)
        return send(stands: { tab.expectsMarkedUnread(false) && alive() }, current: current,
                    refused: { _ in tab.dropExpectedMarkedUnread(false) }, write)
    }

    /// Clears the agent's mark `request` on `tab` (already shown cleared, ``TabModel/expectAttentionClear()``) the same
    /// way. The clear names its request, so a newer mark the agent made meanwhile stays, shows, and ends this write.
    @discardableResult
    public func clearAttention(_ request: TabAttention, of tab: TabModel, alive: @escaping @MainActor () -> Bool = { true },
                               current: @escaping @MainActor () -> Bool = { true },
                               _ write: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        send(stands: { tab.expectsAttentionClear(request) && alive() }, current: current,
             refused: { _ in tab.dropExpectedAttentionClear(request) }, write)
    }
}

extension DaemonStore {
    /// Whether `tab` still stands for the record the person read (``TabReads``' `current`): the daemon generation the
    /// read was made on, and the tab still in the tree (a removed tab's surface may be another tab's on the next
    /// daemon).
    public func holdsRead(of tab: TabModel) -> @MainActor () -> Bool {
        let made = generation
        return { [weak self] in
            guard let self else { return false }
            return generation == made && self.tab(id: tab.id) === tab
        }
    }

    /// The transport whose tree the store shows, for a read that names one of its surfaces
    /// (``DaemonConnection/acknowledgeNotifications(of:on:)``). Before a new connection's first tree lands the store
    /// still shows the last one's, and a daemon that numbers surfaces anew may answer: the read waits, as unanswered.
    /// Nil for a connection with no stamp (the read goes on whichever transport is up).
    public func liveTreeStamp() throws -> DaemonControlStamp? {
        guard liveTreeEpoch == connectionEpoch else { throw DaemonError.notConnected }
        return sideEvents.controlStamp
    }
}
