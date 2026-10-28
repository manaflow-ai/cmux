#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// The host half of the page call behind the refactor oracle's `webviews` facet
/// (webviews/src/protocol/oracle-state.ts). A DEV or bench build installs ``PageWebView/oracleStateScript`` at
/// document start, so only there does a page register `cmux.page.oracle.state`; a Release build compiles none of
/// this and its pages never serve the op.
extension PageRouter {
    /// The op a page serves (`ORACLE_STATE_OP`).
    public nonisolated static let oracleStateOp = "cmux.page.oracle.state"
    /// What a page calls when a reading it contributes changed (`ORACLE_STATE_CHANGED_OP`); the router answers it
    /// itself and runs ``oracleStateChanged``.
    public nonisolated static let oracleStateChangedOp = "cmux.page.oracle.changed"

    /// Asks the page for its state. A page that does not answer by `deadline` (no receive hook, a handler that
    /// never settles, a hung content process) is ``PageWebView/OracleStateAnswer/timedOut``, never a wait with no end.
    ///
    /// - Throws: The page's own error (`cmux.oracle.no_digest` when it cannot hash its draft).
    public func oracleState(within deadline: Duration,
                            clock: any Clock<Duration>) async throws(PageError) -> PageWebView.OracleStateAnswer {
        let call = PendingCall()
        do {
            let state = try await Deadline(deadline, clock: clock).run(Self.oracleStateOp) { @MainActor [self] in
                // A limit that passed before this ran cancelled it: nothing is sent, so nothing waits here.
                try Task.checkCancellation()
                return try await callPage(Self.oracleStateOp, params: .object([:])) { call.id = $0 }
            }
            return .state(state)
        } catch is Deadline.Exceeded {
            // Back on the main actor: the call leaves the router in this turn.
            if let id = call.id { abandonCall(id) }
            return .timedOut
        } catch let error as PageError {
            switch error.code {
            case PageError.unknownOp(Self.oracleStateOp).code: return .unserved
            case PageError.closed.code: return .gone
            default: throw error
            }
        } catch {
            throw PageError(code: "cmux.page.failed", message: String(describing: error))
        }
    }
}

/// The id of a host call once it is pending (``PageRouter/callPage(_:params:started:)``).
private final class PendingCall {
    var id: UInt64?
}

extension PageWebView {
    /// Sets the page's gate (`ORACLE_STATE_ENABLED`) before the page's code runs.
    nonisolated static let oracleStateScript = "globalThis.__cmuxOracleState = true;"

    /// What a page said to ``oracleState(within:clock:)``.
    public enum OracleStateAnswer: Sendable, Equatable {
        /// The page's `{route, selection, panels, draftSha256}`.
        case state(JSONValue)
        /// The document does not serve the op (it does not boot through the shared page client).
        case unserved
        /// No document of this page runs yet: it loads, or reloads after a crash or a discard.
        case loading
        /// The page did not answer by the deadline.
        case timedOut
        /// The page closed or navigated away while it was asked.
        case gone
    }

    /// Asks the page for its state. Nil only for the parked spare, whose document has no routes and that no
    /// person can reach.
    ///
    /// - Throws: The page's own error (`cmux.oracle.no_digest` when it cannot hash its draft).
    public func oracleState(within deadline: Duration,
                            clock: any Clock<Duration>) async throws(PageError) -> OracleStateAnswer? {
        guard !isParkedSpare else { return nil }
        guard loaded else { return .loading }
        return try await router.oracleState(within: deadline, clock: clock)
    }
}

/// Says "a page's oracle reading may have changed" to every subscriber (``WebUIHost/oracleChanges``).
/// `debug.oracle.wait_for` on the `webviews` facet subscribes, so a wait on a draft or a route wakes at the page's
/// own change point, never by a poll. Each subscriber buffers at most one pending signal: it only says "read again".
public nonisolated final class PageOracleChangeFeed: Sendable {
    private nonisolated struct State {
        var next = 0
        var subscribers: [Int: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// A new subscription; it ends when the subscriber stops iterating it.
    public func subscribe() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            defer { state.next += 1 }
            state.subscribers[state.next] = continuation
            return state.next
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// A page's oracle reading may have changed.
    public func signal() {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for continuation in subscribers { continuation.yield() }
    }
}
#endif
