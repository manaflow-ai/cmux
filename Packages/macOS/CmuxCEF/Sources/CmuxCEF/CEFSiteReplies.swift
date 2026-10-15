import Foundation

/// The shim's one-shot asynchronous calls that answer with a `.reply` event
/// (`cmux_shim_clear_cookies`, `cmux_shim_import_cookies`,
/// `cmux_shim_visit_cookies`, ...): allocates their reply ids and waits for
/// the reply. Every caller of such a shim function goes through ``call``, so
/// reply ids never collide.
///
/// A reply can arrive while the shim call is still on the stack (the shim
/// emits on the UI thread, which is the main thread here); it is kept for its
/// id and returned at once. When Chromium shuts down, waiting calls fail at
/// once (``failAll(with:)``, from `CEFRuntime.shutdown`) and new calls are
/// refused, so quitting never waits out a call's timeout.
@MainActor
public final class CEFSiteReplies {
    /// A reply's integer and JSON payload.
    public struct Reply: Equatable, Sendable {
        public var value: Int64
        public var json: String
    }

    /// What the replies need from the runtime; tests pass fakes.
    struct Environment {
        /// Why calls cannot run now; `nil` while Chromium runs and is not shutting down.
        var unavailableReason: @MainActor () -> CEFUnavailableReason?
        /// Starts delivering shim events (called once, on first use).
        var observe: @MainActor (@escaping @MainActor (CEFShimEvent) -> Void) -> Void
    }

    public static let shared = CEFSiteReplies(runtime: .shared)

    private let environment: Environment
    private let waiters = CEFReplyWaiters<Int32, Reply>()
    private var nextID: Int32 = 1
    private var pending: Set<Int32> = []
    private var early: [Int32: Reply] = [:]
    private var observing = false

    convenience init(runtime: CEFRuntime) {
        self.init(environment: Environment(
            unavailableReason: { [unowned runtime] in
                if runtime.isShuttingDown { return .shutDown }
                return runtime.isRunning ? nil : (runtime.unavailableReason ?? .notBundled)
            },
            observe: { [unowned runtime] observer in _ = runtime.addEventObserver(observer) }
        ))
    }

    init(environment: Environment) {
        self.environment = environment
    }

    /// Calls suspended waiting for a reply.
    var waitingCount: Int { waiters.count }

    /// Calls one shim function that answers with a `.reply` event.
    /// - Parameters:
    ///   - label: Names the call in a timeout error.
    ///   - timeout: How long to wait for the reply.
    ///   - start: Starts the call with the reply id; returns 1 when it started.
    /// - Returns: The reply.
    /// - Throws: ``CEFError/unavailable(_:)`` when Chromium is not running (or
    ///   is shutting down), ``CEFError/browserClosed`` when the call did not
    ///   start or Chromium shut down while it waited, ``CEFError/timedOut(_:)``
    ///   when no reply came in time.
    public func call(label: String, timeout: Duration, start: (Int32) -> Int32) async throws -> Reply {
        if let reason = environment.unavailableReason() { throw CEFError.unavailable(reason) }
        observeIfNeeded()
        let id = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        pending.insert(id)
        defer {
            pending.remove(id)
            early[id] = nil
        }
        guard start(id) == 1 else { throw CEFError.browserClosed }
        if let reply = early[id] { return reply }
        return try await waiters.reply(for: id, timeout: timeout) { CEFError.timedOut("\(label) (\(timeout))") }
    }

    /// Fails every waiting call at once (Chromium is shutting down).
    public func failAll(with error: any Error = CEFError.browserClosed) {
        waiters.failAll(where: { _ in true }, with: error)
    }

    /// Delivers one shim event (also the entry point for tests).
    func receive(_ event: CEFShimEvent) {
        guard case let .reply(_, id, value, json) = event, pending.contains(id) else { return }
        let reply = Reply(value: value, json: json)
        if !waiters.resolve(id, with: .success(reply)) {
            early[id] = reply
        }
    }

    private func observeIfNeeded() {
        guard !observing else { return }
        observing = true
        environment.observe { [weak self] event in self?.receive(event) }
    }
}
