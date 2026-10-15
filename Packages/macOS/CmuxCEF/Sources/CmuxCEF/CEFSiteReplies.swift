import Foundation

/// The shim's one-shot asynchronous calls that answer with a `.reply` event
/// (`cmux_shim_clear_cookies`, `cmux_shim_import_cookies`,
/// `cmux_shim_visit_cookies`, ...): allocates their reply ids and waits for
/// the reply. Every caller of such a shim function goes through ``call``, so
/// reply ids never collide.
///
/// A reply can arrive while the shim call is still on the stack (the shim
/// emits on the UI thread, which is the main thread here); it is kept for its
/// id and returned at once.
@MainActor
public final class CEFSiteReplies {
    /// A reply's integer and JSON payload.
    public struct Reply: Equatable, Sendable {
        public var value: Int64
        public var json: String
    }

    public static let shared = CEFSiteReplies(runtime: .shared)

    private let runtime: CEFRuntime
    private let waiters = CEFReplyWaiters<Int32, Reply>()
    private var nextID: Int32 = 1
    private var pending: Set<Int32> = []
    private var early: [Int32: Reply] = [:]
    private var observer: UUID?

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    /// Calls one shim function that answers with a `.reply` event.
    /// - Parameters:
    ///   - label: Names the call in a timeout error.
    ///   - timeout: How long to wait for the reply.
    ///   - start: Starts the call with the reply id; returns 1 when it started.
    /// - Returns: The reply.
    /// - Throws: ``CEFError/unavailable(_:)`` when Chromium is not running,
    ///   ``CEFError/browserClosed`` when the call did not start,
    ///   ``CEFError/timedOut(_:)`` when no reply came in time.
    public func call(label: String, timeout: Duration, start: (Int32) -> Int32) async throws -> Reply {
        guard runtime.isRunning else { throw CEFError.unavailable(runtime.unavailableReason ?? .notBundled) }
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

    private func observeIfNeeded() {
        guard observer == nil else { return }
        observer = runtime.addEventObserver { [weak self] event in
            guard case let .reply(_, id, value, json) = event else { return }
            self?.deliver(id: id, reply: Reply(value: value, json: json))
        }
    }

    private func deliver(id: Int32, reply: Reply) {
        guard pending.contains(id) else { return }
        if !waiters.resolve(id, with: .success(reply)) {
            early[id] = reply
        }
    }
}
