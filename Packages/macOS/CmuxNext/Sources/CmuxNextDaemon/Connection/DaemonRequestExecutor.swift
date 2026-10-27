import Foundation

/// Executes typed wire requests on one captured transport, without rebinding or admission.
struct DaemonRequestExecutor: Sendable {
    let transport: LineTransport

    func perform<R: DaemonRequest>(_ request: R, timeout: Duration?) async throws -> R.Response {
        let response = try await transport.request(cmd: R.commandName, timeout: timeout) { id in
            try WireCoding.encodeRequest(request, id: id)
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response)
    }
}
