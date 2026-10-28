public import CmuxNextSettings
public import Foundation

/// The host verb `cmux.host.cause.person {transaction}` (p06-scheduler.md "Page
/// relay"). A page that sends ops on its own daemon WebSocket (the channels Home's
/// `conversation-op`) goes past every app connection, so none knows the op is the person's. Before
/// such a send the page names the op's client `transaction`, which the daemon echoes in the op's
/// events (cmux-tui conversations.rs `commit_op`, conversation_store.rs
/// `ConversationEvent::wire_json`). When a real key or pointer event in the page backs the call
/// (``PageCallContext/userGesture``, the host's record within 1 s, like Chrome's transient user
/// activation, third_party/blink/common/frame/user_activation_state.cc), the route hands the
/// transaction to `record`, which the app points at the ledgers of its connections that hear the
/// echo, so it applies as the person's change. Each event backs one call: page script inside the
/// gesture's second cannot claim a second op. Without a gesture nothing is recorded and the echo
/// keeps the daemon's cause for the page. Scheduling only: the daemon's origin and authorization
/// are unchanged.
///
/// ```swift
/// let causes = PagePersonCauseRoute { transaction in
///     connection.mutationCauses.record(transaction: ClientTransactionID(rawValue: transaction), cause: .person)
/// }
/// ```
@MainActor
public final class PagePersonCauseRoute: PageProvider {
    /// The namespace a page lists to claim its gesture-backed ops.
    public nonisolated static let prefix = "cmux.host.cause."
    /// The one op: `{transaction}` -> `{person}`.
    public nonisolated static let personOp = prefix + "person"
    /// Records a scheduling cause only; declared as `act`, the stronger kind, so the page's process
    /// group reads it as a change.
    public nonisolated static let table = PageOpTable(namespace: prefix, act: ["person"])

    private let record: @MainActor (String) -> Void
    /// The event uptime of the last gesture a claim spent.
    private var spentGesture: TimeInterval?

    /// - Parameter record: Records one gesture-backed `transaction` as the person's.
    public init(record: @escaping @MainActor (String) -> Void) {
        self.record = record
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.personOp else { throw PageError.unknownOp(op) }
        guard let transaction = params["transaction"]?.stringValue, Self.isValidTransaction(transaction) else {
            throw PageError.invalidParams("transaction must be 1-128 printable ASCII characters")
        }
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
            return .object(["person": .bool(false)])
        }
        spentGesture = event
        record(transaction)
        return .object(["person": .bool(true)])
    }

    /// The daemon's rule for a client `transaction` (cmux-tui server.rs `validate_client_transaction`):
    /// 1-128 printable ASCII characters, no space.
    public nonisolated static func isValidTransaction(_ transaction: String) -> Bool {
        (1...128).contains(transaction.utf8.count) && transaction.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}
