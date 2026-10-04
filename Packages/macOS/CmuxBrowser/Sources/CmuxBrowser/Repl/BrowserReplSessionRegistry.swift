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
/// Sessions are keyed by workspace and name (``BrowserReplSessionKey``). At
/// most ``maximumSessions`` live at once: each holds a JavaScript thread,
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
    }

    /// The longest session name.
    public static let maximumNameLength = 64
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
    /// - Throws: ``Refusal``.
    public func session(
        for key: BrowserReplSessionKey,
        make: (_ instanceID: String) -> BrowserReplSession
    ) throws -> BrowserReplSession {
        guard Self.isValidName(key.name) else { throw Refusal.invalidName }
        lock.lock()
        let session: BrowserReplSession
        if let existing = sessions[key], !existing.isClosed {
            session = existing
        } else {
            let live = sessions.values.filter { !$0.isClosed }.count
            guard live < maximumSessions else {
                lock.unlock()
                throw Refusal.tooManySessions(limit: maximumSessions)
            }
            session = make(key.makeInstanceID())
            sessions[key] = session
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

    /// Closes and forgets the session for `key`.
    /// - Returns: Whether a session existed.
    @discardableResult
    public func reset(_ key: BrowserReplSessionKey) -> Bool {
        lock.lock()
        let session = sessions.removeValue(forKey: key)
        let timerID = timerIDs.removeValue(forKey: key)
        if let timerID { keysByTimerID.removeValue(forKey: timerID) }
        lock.unlock()
        if let timerID { scheduler.cancel(id: timerID) }
        session?.close()
        return session != nil
    }

    /// Closes and forgets the sessions named `name` in `workspaceID`, or in
    /// every workspace when it is `nil`.
    /// - Returns: How many sessions existed.
    @discardableResult
    public func reset(name: String, workspaceID: UUID?) -> Int {
        let keys = lock.withLock {
            sessions.keys.filter { $0.name == name && (workspaceID == nil || $0.workspaceID == workspaceID) }
        }
        return keys.filter { reset($0) }.count
    }

    /// Live sessions of `workspaceID`, or of every workspace when it is
    /// `nil`, sorted by name.
    public func list(workspaceID: UUID?) -> [Entry] {
        lock.lock()
        let current = sessions.filter { !$0.value.isClosed && (workspaceID == nil || $0.key.workspaceID == workspaceID) }
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
        lock.unlock()
        if idle < idleTimeout {
            scheduler.schedule(id: timerID, after: idleTimeout - idle, repeating: false)
            return
        }
        reset(key)
    }
}
