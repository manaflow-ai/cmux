import Foundation
import os

/// The connect handshake's request lines (`DaemonConnection.handshake`).
enum HandshakeLines {
    /// Sends the handshake and returns the replies of `identify`,
    /// `set-client-info` and `subscribe`, in that order. Without
    /// `clientHello` the three go out in one round trip. With it,
    /// `client-hello` step 1 rides with `identify`, and its proof (step 2,
    /// P8 3b-2) leads the second round trip so it directly follows step 1.
    static func send(_ transport: LineTransport, configuration: DaemonConnectionConfiguration,
                     logger: Logger) async -> [Result<LineTransport.Response, any Error>] {
        let setup = [
            PipelinedLine(SetClientInfoRequest(name: configuration.clientName, kind: "frontend",
                                               capabilities: configuration.handshakeCapabilities)),
            PipelinedLine(SubscribeRequest(treeEvents: configuration.treeEvents)),
        ]
        guard let hello = configuration.clientHello else {
            return await transport.pipeline([PipelinedLine(IdentifyRequest())] + setup, timeout: configuration.requestTimeout)
        }
        let first = await transport.pipeline([
            PipelinedLine(IdentifyRequest()),
            PipelinedLine(ClientHelloStartRequest(installID: hello.installKey?.installID)),
        ], timeout: configuration.requestTimeout)
        let proof = helloProof(hello, start: first[1])
        let rest = await transport.pipeline((proof.map { [PipelinedLine($0)] } ?? []) + setup,
                                            timeout: configuration.requestTimeout)
        if proof != nil, let verified = try? rest[0].get() {
            let ok = (try? WireCoding.decodeResponse(ClientHelloProofRequest.Response.self, from: verified.line))?.verified == true
            logger.info("client-hello install-key proof \(ok ? "accepted" : "refused", privacy: .public)")
        }
        return [first[0]] + rest.suffix(2)
    }

    /// Step 2 of `client-hello` when step 1 returned a nonce and the app
    /// holds an install key; nil otherwise (an older daemon answers step 1
    /// with an error, which only leaves the connection unverified).
    static func helloProof(_ hello: ClientHelloIdentity,
                           start: Result<LineTransport.Response, any Error>) -> ClientHelloProofRequest? {
        guard let key = hello.installKey, let line = try? start.get().line,
              let nonce = (try? WireCoding.decodeResponse(ClientHelloStartRequest.Response.self, from: line))?.nonce,
              let proof = key.proof(nonceHex: nonce) else { return nil }
        return ClientHelloProofRequest(installID: key.installID, proof: proof)
    }
}
