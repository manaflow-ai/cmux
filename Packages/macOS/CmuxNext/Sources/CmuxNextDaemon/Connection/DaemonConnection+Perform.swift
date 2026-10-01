import Foundation

extension DaemonConnection {
    /// Sends `request` on `transport` and decodes its response.
    static func perform<R: DaemonRequest>(_ request: R, on transport: LineTransport,
                                          timeout: Duration? = defaultRequestTimeout) async throws -> R.Response {
        let response = try await transport.request(cmd: R.command, timeout: timeout) { id in
            try WireCoding.encodeRequest(request, id: id)
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response.line)
    }
}
