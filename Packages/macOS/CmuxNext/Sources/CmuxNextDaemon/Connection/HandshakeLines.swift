import Foundation
import os

/// The connect handshake's request lines (`DaemonConnection.handshake`).
enum HandshakeLines {
    /// The replies of `identify`, `set-client-info` and `subscribe`, in that
    /// order, and whether the daemon accepts origin `user` on the
    /// connection: the last `client-hello` reply's `user_origin_allowed`
    /// (false without a hello, from an older daemon, or on any error).
    struct Replies {
        var lines: [Result<LineTransport.Response, any Error>]
        var userOriginAllowed: Bool
    }

    /// Sends the handshake. Without `clientHello` the three lines go out in
    /// one round trip. With it, `client-hello` step 1 rides with `identify`,
    /// and its proof (step 2, P8 3b-2) leads the second round trip so it
    /// directly follows step 1.
    static func send(_ transport: LineTransport, configuration: DaemonConnectionConfiguration,
                     logger: Logger) async -> Replies {
        let setup = [
            PipelinedLine(SetClientInfoRequest(name: configuration.clientName, kind: "frontend",
                                               capabilities: configuration.handshakeCapabilities)),
            PipelinedLine(SubscribeRequest(treeEvents: configuration.treeEvents)),
        ]
        guard let hello = configuration.clientHello else {
            let lines = await transport.pipeline([PipelinedLine(IdentifyRequest())] + setup, timeout: configuration.requestTimeout)
            return Replies(lines: lines, userOriginAllowed: false)
        }
        let first = await transport.pipeline([
            PipelinedLine(IdentifyRequest()),
            PipelinedLine(ClientHelloRequest(role: .main, installID: hello.installKey?.installID)),
        ], timeout: configuration.requestTimeout)
        let started = (try? first[1].get()).flatMap { try? WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: $0.line) }
        let proof = helloProof(hello, start: first[1])
        let rest = await transport.pipeline((proof.map { [PipelinedLine($0)] } ?? []) + setup,
                                            timeout: configuration.requestTimeout)
        var userOriginAllowed = started?.userOriginAllowed == true
        if proof != nil {
            let proved = (try? rest[0].get()).flatMap { try? WireCoding.decodeResponse(ClientHelloProofRequest.Response.self, from: $0.line) }
            logger.info("client-hello install-key proof \(proved?.verified == true ? "accepted" : "refused", privacy: .public)")
            userOriginAllowed = proved?.verified == true && proved?.userOriginAllowed == true
        }
        return Replies(lines: [first[0]] + rest.suffix(2), userOriginAllowed: userOriginAllowed)
    }

    /// Step 2 of `client-hello` when step 1 returned a nonce and the app
    /// holds an install key; nil otherwise (an older daemon answers step 1
    /// with an error, which only leaves the connection unverified).
    static func helloProof(_ hello: ClientHelloIdentity,
                           start: Result<LineTransport.Response, any Error>) -> ClientHelloProofRequest? {
        guard let key = hello.installKey, let line = try? start.get().line,
              let nonce = (try? WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: line))?.nonce,
              let proof = key.proof(nonceHex: nonce) else { return nil }
        return ClientHelloProofRequest(installID: key.installID, proof: proof)
    }
}
