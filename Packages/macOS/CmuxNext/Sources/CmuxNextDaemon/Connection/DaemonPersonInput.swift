/// A request a view sends for the person using it: typed text, a paste or keys to a surface
/// (p01-process-235). A `send` by terminal id is not one: it must stay behind the create it follows.
public protocol PersonInputRequest: DaemonRequest {}

extension SendInputRequest: PersonInputRequest {}
extension SendKeyRequest: PersonInputRequest {}

/// The person's input on one ``DaemonConnection`` (p01-process-235). Its lines leave the app's socket writer in
/// call order with every other request line, so a key never passes a resize or an attach of its own surface that
/// was sent before it. cmux-tui runs them on the connection's person-input lane, ahead of the control requests of
/// other surfaces it holds, and keeps each surface's order there (daemon feature `daemonPersonInputLane`; without
/// it they run in arrival order). This is Chromium's input path: input events run on their own queue first
/// (third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc), and the reordering
/// happens where the per-target order is known, not on the wire.
public struct DaemonPersonInput: Sendable {
    private let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// Sends `request` and decodes its reply, within the connection's request deadline.
    /// Runs on the caller's executor with no actor hop, as ``DaemonConnection/request(_:)``.
    public func send<R: PersonInputRequest>(_ request: R) async throws -> R.Response {
        try await connection.request(request)
    }
}
