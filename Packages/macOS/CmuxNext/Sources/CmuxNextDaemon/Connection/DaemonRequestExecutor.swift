import Foundation

/// Executes typed wire requests on one captured transport, without rebinding or admission.
///
/// A typed request is a v12 command, so once the connection holds `ipc-frames-v2` it goes as a REQUEST frame
/// whose header names its method by the injected ``DaemonWireUpgrades/methodTable`` (``FramedRequests``); its
/// reply is the same JSON either way. A method the daemon serves only as a line is refused on its frame before
/// it runs (`method_not_framed`): the transport sends that method as a line from then on, and this request goes
/// again as one. Other callers of the transport (v2 resource envelopes, raw lines) stay lines.
struct DaemonRequestExecutor: Sendable {
    let transport: LineTransport

    func perform<R: DaemonRequest>(_ request: R, timeout: Duration?) async throws -> R.Response {
        let response: LineTransport.Response
        do {
            response = try await send(request, timeout: timeout, framed: true)
        } catch DaemonError.command(_, _, let code?, _, _) where code == FramedRequests.methodNotFramed {
            response = try await send(request, timeout: timeout, framed: false)
        }
        return try WireCoding.decodeResponse(R.Response.self, from: response)
    }

    private func send<R: DaemonRequest>(_ request: R, timeout: Duration?, framed: Bool) async throws -> LineTransport.Response {
        try await transport.request(cmd: R.commandName, timeout: timeout, framed: framed) { id in
            try WireCoding.encodeRequest(request, id: id)
        }
    }
}
