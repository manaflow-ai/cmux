import Foundation

/// Keeps named REPL sessions alive between CLI calls and closes idle ones.
///
/// Each touch re-arms the session's idle timer on a shared
/// `BrowserReplTimerScheduler`, so expiry needs no polling and is cancelled
/// when the session is reset or used again.
public final class BrowserReplSessionRegistry: @unchecked Sendable {
    /// A listed session.
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let cwd: String
        public let idleSeconds: Int
    }

    private let lock = NSLock()
    private var sessions: [String: BrowserReplSession] = [:]
    private var timerIDs: [String: Int] = [:]
    private var namesByTimerID: [Int: String] = [:]
    private var nextTimerID = 0
    private let idleTimeout: Duration
    private var scheduler: BrowserReplTimerScheduler<ContinuousClock>!

    /// - Parameter idleTimeout: A session unused this long is closed.
    public init(idleTimeout: Duration = .seconds(30 * 60)) {
        self.idleTimeout = idleTimeout
        self.scheduler = BrowserReplTimerScheduler(clock: ContinuousClock()) { [weak self] timerID in
            self?.expire(timerID: timerID)
        }
    }

    /// Returns the live session named `id`, creating it with `make` when absent.
    /// Re-arms the idle timer.
    public func session(named id: String, make: () -> BrowserReplSession) -> BrowserReplSession {
        lock.lock()
        let session: BrowserReplSession
        if let existing = sessions[id], !existing.isClosed {
            session = existing
        } else {
            session = make()
            sessions[id] = session
        }
        let timerID = timerIDs[id] ?? {
            nextTimerID += 1
            timerIDs[id] = nextTimerID
            namesByTimerID[nextTimerID] = id
            return nextTimerID
        }()
        lock.unlock()
        scheduler.schedule(id: timerID, after: idleTimeout, repeating: false)
        return session
    }

    /// Closes and forgets session `id`.
    /// - Returns: Whether a session existed.
    @discardableResult
    public func reset(named id: String) -> Bool {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        let timerID = timerIDs.removeValue(forKey: id)
        if let timerID { namesByTimerID.removeValue(forKey: timerID) }
        lock.unlock()
        if let timerID { scheduler.cancel(id: timerID) }
        session?.close()
        return session != nil
    }

    /// Live sessions sorted by name.
    public func list() -> [Entry] {
        lock.lock()
        let current = sessions.values.filter { !$0.isClosed }
        lock.unlock()
        let now = ContinuousClock.now
        return current
            .map { Entry(id: $0.id, cwd: $0.cwd, idleSeconds: Int((now - $0.lastUsed).components.seconds)) }
            .sorted { $0.id < $1.id }
    }

    private func expire(timerID: Int) {
        lock.lock()
        guard let id = namesByTimerID[timerID], let session = sessions[id] else {
            lock.unlock()
            return
        }
        // The timer was armed by the last `session(named:)` call. `lastUsed`
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
        reset(named: id)
    }
}
