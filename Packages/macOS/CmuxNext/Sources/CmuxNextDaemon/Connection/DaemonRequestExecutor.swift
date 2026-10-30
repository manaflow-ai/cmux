import Foundation

/// Executes typed wire requests on one captured transport, without rebinding or admission.
///
/// A typed request is a v12 command, so once the connection holds `ipc-frames-v2` it goes as a REQUEST frame
/// when the daemon listed its method as answered on frames (``FramedRequests``); its reply is the same JSON
/// either way. Every other command stays a line, so no request is refused for its encoding and none is sent
/// twice. Other callers of the transport (v2 resource envelopes, raw lines) stay lines.
struct DaemonRequestExecutor: Sendable {
    let transport: LineTransport

    /// `opening`: the stream `request` opens (`attach-surface {stream}`); framed, its header names it.
    func perform<R: DaemonRequest>(_ request: R, timeout: Duration?,
                                   opening: AttachStreamHandle? = nil) async throws -> R.Response {
        let response = try await transport.request(cmd: R.commandName, timeout: timeout, framed: true,
                                                   opening: opening) { id in
            try WireCoding.encodeRequest(request, id: id)
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response)
    }
}
