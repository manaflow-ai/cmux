import CmuxNextIPC
import Foundation

/// Executes typed wire requests on one captured transport, without rebinding or admission.
struct DaemonRequestExecutor: Sendable {
    let transport: LineTransport

    /// - Parameter priority: The writer FIFO the request's line waits in: `.input` for a person's input
    ///   (``DaemonPersonInput``), `.control` for everything else.
    func perform<R: DaemonRequest>(_ request: R, timeout: Duration?, priority: MethodPriority = .control) async throws -> R.Response {
        let response = try await transport.request(cmd: R.commandName, timeout: timeout, priority: priority) { id in
            try WireCoding.encodeRequest(request, id: id)
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response)
    }
}
