public import Foundation

/// A named REPL session's identity: the same name in another workspace is
/// another session.
public struct BrowserReplSessionKey: Hashable, Sendable {
    public let workspaceID: UUID
    public let name: String

    public init(workspaceID: UUID, name: String) {
        self.workspaceID = workspaceID
        self.name = name
    }

    /// The key an instance id from ``BrowserReplSessionRegistry/session(for:make:)``
    /// was made for, or `nil` for another string.
    public init?(instanceID: String) {
        let parts = instanceID.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let workspaceID = UUID(uuidString: String(parts[0])),
              UUID(uuidString: String(parts[1])) != nil, !parts[2].isEmpty else { return nil }
        self.init(workspaceID: workspaceID, name: String(parts[2]))
    }

    /// A new id for one instance of this session, never reused: driver
    /// state (tab ownership, domain policy, cleanup) keys on it, so a reset
    /// session's late teardown never reaches a new session of the same name.
    func makeInstanceID() -> String {
        "\(workspaceID.uuidString)/\(UUID().uuidString)/\(name)"
    }
}

/// Keeps named REPL sessions alive between CLI calls and closes idle ones.
///
/// Sessions are keyed by workspace and name (``BrowserReplSessionKey``). A
/// session a client makes without a name of its own (one-shot, interactive
/// and MCP runs without `--session`) carries that client's owner token, a
/// random string only the client holds: it is left out of every other
/// caller's list, and attaching to it or resetting it needs the token, so
/// knowing or guessing its name gives another local client nothing. A
/// token is taken only with such a client-made name (``isPrivateName(_:)``):
/// a name a person chose is shared, and a token on it would hide it from
/// every other client while it holds the name. At most ``maximumSessions`` live at once: each holds a JavaScript thread,
/// timers and directories, so one more is refused rather than an idle one
/// evicted. Each touch re-arms the session's idle timer on a shared
/// `BrowserReplTimerScheduler`, so expiry needs no polling and is cancelled
/// when the session is reset or used again.
public final class BrowserReplSessionRegistry: @unchecked Sendable {
    /// A listed session.
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let workspaceID: UUID
        public let cwd: String
        public let idleSeconds: Int
    }

    /// Why ``session(for:make:)`` made no session.
    public enum Refusal: Error, Equatable, Sendable {
        /// The name is empty, longer than ``maximumNameLength`` or has a
        /// character outside `A-Z a-z 0-9 . _ -`.
        case invalidName
        /// ``maximumSessions`` sessions are live.
        case tooManySessions(limit: Int)
        /// A live session of that name belongs to another client (its
        /// owner token is not the caller's).
        case ownedByAnotherClient
        /// The owner token is empty or longer than ``maximumOwnerBytes``.
        case invalidOwner
        /// An owner token came with a shared name, one that is not a
        /// client-made private name (``isPrivateName(_:)``).
        case ownerOnSharedName
    }

    /// The prefixes of the names clients make for a session only they use
    /// (the interactive CLI's `cli-`, `mcp`'s `mcp-`, the socket's own
    /// one-shot `oneshot-`), the only names an owner token may come with.
    public static let privateNamePrefixes = ["cli-", "mcp-", "oneshot-"]

    /// Whether `name` is a client-made private name that may carry an
    /// owner token.
    public static func isPrivateName(_ name: String) -> Bool {
        privateNamePrefixes.contains { name.hasPrefix($0) }
    }

    /// The longest session name.
    public static let maximumNameLength = 64
    /// The longest owner token, in UTF-8 bytes. The token comes from the
    /// socket and is kept with its session, so it is bounded like the name.
    public static let maximumOwnerBytes = 128

    /// Whether `owner` can be a session's owner token (nil: no owner).
    public static func isValidOwner(_ owner: String?) -> Bool {
        guard let owner else { return true }
        return !owner.isEmpty && owner.utf8.count <= maximumOwnerBytes
    }

    /// Live sessions an instance keeps by default.
    public static let defaultMaximumSessions = 32

    /// Whether `name` can name a session.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.unicodeScalars.count <= maximumNameLength else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }
    }

    public let maximumSessions: Int
    private let lock = NSLock()
    private var sessions: [BrowserReplSessionKey: BrowserReplSession] = [:]
    /// The owner token of each session made with one.
    private var owners: [BrowserReplSessionKey: String] = [:]
    private var timerIDs: [BrowserReplSessionKey: Int] = [:]
    private var keysByTimerID: [Int: BrowserReplSessionKey] = [:]
    private var nextTimerID = 0
    private let idleTimeout: Duration
    private var scheduler: BrowserReplTimerScheduler<ContinuousClock>!

    /// - Parameters:
    ///   - idleTimeout: A session unused this long is closed.
    ///   - maximumSessions: Live sessions at most.
    public init(idleTimeout: Duration = .seconds(30 * 60), maximumSessions: Int = BrowserReplSessionRegistry.defaultMaximumSessions) {
        self.idleTimeout = idleTimeout
        self.maximumSessions = maximumSessions
        self.scheduler = BrowserReplTimerScheduler(clock: ContinuousClock()) { [weak self] timerID in
            self?.expire(timerID: timerID)
        }
    }

    /// Returns the live session for `key`, creating it with `make` when
    /// absent. `make` gets the new instance's id
    /// (``BrowserReplSessionKey/init(instanceID:)`` reads it back). Re-arms
    /// the idle timer.
    /// - Parameter owner: The calling client's owner token for a session
    ///   only it may use, or nil for a named session any client shares. A
    ///   live session is returned only to a caller with its token (nil for
    ///   one made without).
    /// - Throws: ``Refusal``.
    public func session(
        for key: BrowserReplSessionKey,
        owner: String? = nil,
        make: (_ instanceID: String) -> BrowserReplSession
    ) throws -> BrowserReplSession {
        guard Self.isValidName(key.name) else { throw Refusal.invalidName }
        guard Self.isValidOwner(owner) else { throw Refusal.invalidOwner }
        guard owner == nil || Self.isPrivateName(key.name) else { throw Refusal.ownerOnSharedName }
        lock.lock()
        let session: BrowserReplSession
        if let existing = sessions[key], !existing.isClosed {
            guard owners[key] == owner else {
                lock.unlock()
                throw Refusal.ownedByAnotherClient
            }
            session = existing
        } else {
            let live = sessions.values.filter { !$0.isClosed }.count
            guard live < maximumSessions else {
                lock.unlock()
                throw Refusal.tooManySessions(limit: maximumSessions)
            }
            session = make(key.makeInstanceID())
            // A session that ended by itself (its JavaScript heap passed
            // its limit) tells the next one of its name, for the same client.
            if let ended = sessions[key], owners[key] == owner, let reason = ended.endedReason {
                session.noteBeforeNextCell("cmux browser repl: this is a new session; the last one named '\(key.name)' ended: \(reason)")
            }
            sessions[key] = session
            owners[key] = owner
        }
        let timerID = timerIDs[key] ?? {
            nextTimerID += 1
            timerIDs[key] = nextTimerID
            keysByTimerID[nextTimerID] = key
            return nextTimerID
        }()
        lock.unlock()
        scheduler.schedule(id: timerID, after: idleTimeout, repeating: false)
        return session
    }

    /// Closes and forgets the session for `key`, when `owner` is its owner
    /// token (nil for a session made without one).
    /// - Returns: Whether such a session existed.
    @discardableResult
    public func reset(_ key: BrowserReplSessionKey, owner: String? = nil) -> Bool {
        remove(key, ifOwnedBy: owner)
    }

    /// Closes and forgets the session for `key` while its owner token is
    /// `owner`. - Returns: Whether it existed.
    private func remove(_ key: BrowserReplSessionKey, ifOwnedBy owner: String?) -> Bool {
        lock.lock()
        guard owners[key] == owner else {
            lock.unlock()
            return false
        }
        let session = sessions.removeValue(forKey: key)
        owners.removeValue(forKey: key)
        let timerID = timerIDs.removeValue(forKey: key)
        if let timerID { keysByTimerID.removeValue(forKey: timerID) }
        lock.unlock()
        if let timerID { scheduler.cancel(id: timerID) }
        session?.close()
        return session != nil
    }

    /// Closes and forgets the sessions named `name` in `workspaceID`, or in
    /// every workspace when it is `nil`, that `owner` may reset.
    /// - Returns: How many sessions existed.
    @discardableResult
    public func reset(name: String, workspaceID: UUID?, owner: String? = nil) -> Int {
        let keys = lock.withLock {
            sessions.keys.filter { $0.name == name && (workspaceID == nil || $0.workspaceID == workspaceID) }
        }
        return keys.filter { reset($0, owner: owner) }.count
    }

    /// Live sessions of `workspaceID`, or of every workspace when it is
    /// `nil`, sorted by name: the shared ones and those `owner` owns.
    public func list(workspaceID: UUID?, owner: String? = nil) -> [Entry] {
        lock.lock()
        let current = sessions.filter { key, session in
            !session.isClosed && (workspaceID == nil || key.workspaceID == workspaceID)
                && (owners[key] == nil || owners[key] == owner)
        }
        lock.unlock()
        let now = ContinuousClock.now
        return current
            .map { key, session in
                Entry(name: key.name, workspaceID: key.workspaceID, cwd: session.cwd, idleSeconds: Int((now - session.lastUsed).components.seconds))
            }
            .sorted { ($0.name, $0.workspaceID.uuidString) < ($1.name, $1.workspaceID.uuidString) }
    }

    private func expire(timerID: Int) {
        lock.lock()
        guard let key = keysByTimerID[timerID], let session = sessions[key] else {
            lock.unlock()
            return
        }
        // The timer was armed by the last `session(for:)` call. `lastUsed`
        // is when the session last started an evaluation, which is later
        // when a queued cell started after that call; then re-arm for the
        // rest of the idle timeout. Otherwise close the session, even while
        // an evaluation is still running: a cell that runs longer than the
        // idle timeout does not keep its session alive.
        let idle = ContinuousClock.now - session.lastUsed
        let owner = owners[key]
        lock.unlock()
        if idle < idleTimeout {
            scheduler.schedule(id: timerID, after: idleTimeout - idle, repeating: false)
            return
        }
        _ = remove(key, ifOwnedBy: owner)
    }
}
