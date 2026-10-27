import CmuxNextIPC

/// A request a view sends for the person using it: typed text, a paste or keys to a surface
/// (p01-process-235). A `send` by terminal id is not one: it must stay behind the create it follows.
public protocol PersonInputRequest: DaemonRequest {}

extension SendInputRequest: PersonInputRequest {}
extension SendKeyRequest: PersonInputRequest {}

/// The person-input lane of one ``DaemonConnection`` (p01-process-235). Its requests leave the app's socket
/// writer at input priority, before the control and bulk lines queued there, and cmux-tui runs them on the
/// connection's person-input lane, ahead of control requests of other surfaces (daemon feature
/// `daemonPersonInputLane`; without it they run in arrival order). This is Chromium's input path: input
/// events go to the renderer on their own route and run first
/// (content/browser/renderer_host/input/input_router_impl.cc, and Blink's input task queue in
/// third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc).
///
/// Lines of one priority keep their call order. A key can leave before a control line of its own surface
/// that still waits in the writer (a resize, an attach); the daemon then runs the key first.
public struct DaemonPersonInput: Sendable {
    private let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// Sends `request` on the lane and decodes its reply, within the connection's request deadline.
    /// Runs on the caller's executor with no actor hop, as ``DaemonConnection/request(_:timeout:)``.
    public func send<R: PersonInputRequest>(_ request: R) async throws -> R.Response {
        try await connection.sendAdmitted(request, timeout: connection.configuration.requestTimeout,
                                          priority: .input) { request, _ in request }
    }
}
