import Foundation
import CmuxNextCompat
#if canImport(os)
import os
#endif

/// The connect handshake's request lines (`DaemonHandshake`).
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
    /// one round trip; a supporting daemon then supplies explicit owner metadata.
    /// With `clientHello`, step 1 rides with `identify`,
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
            var lines = await transport.pipeline([PipelinedLine(IdentifyRequest())] + setup, timeout: configuration.requestTimeout)
            if servesMachineMetadata(lines[0]) {
                let metadata = await transport.pipeline([PipelinedLine(IdentifyRequest(machineMetadata: true))], timeout: configuration.requestTimeout)
                lines[0] = fencedMetadata(metadata[0], original: lines[0])
            }
            return Replies(lines: lines, userOriginAllowed: false)
        }
        let first = await transport.pipeline([
            PipelinedLine(IdentifyRequest()),
            PipelinedLine(ClientHelloRequest(role: .main, installID: hello.installKey?.installID)),
        ], timeout: configuration.requestTimeout)
        let started = (try? first[1].get()).flatMap { try? WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: $0) }
        let proof = helloProof(hello, start: first[1])
        let metadata = servesMachineMetadata(first[0]) ? [PipelinedLine(IdentifyRequest(machineMetadata: true))] : []
        let rest = await transport.pipeline((proof.map { [PipelinedLine($0)] } ?? []) + metadata + setup,
                                            timeout: configuration.requestTimeout)
        var userOriginAllowed = started?.userOriginAllowed == true
        if proof != nil {
            let proved = (try? rest[0].get()).flatMap { try? WireCoding.decodeResponse(ClientHelloProofRequest.Response.self, from: $0) }
            logger.info("client-hello install-key proof \(proved?.verified == true ? "accepted" : "refused", privacy: .public)")
            userOriginAllowed = proved?.verified == true && proved?.userOriginAllowed == true
        }
        let identity: Result<LineTransport.Response, any Error>
        if metadata.isEmpty {
            identity = first[0]
        } else if let enriched = rest.dropFirst(proof == nil ? 0 : 1).first {
            identity = fencedMetadata(enriched, original: first[0])
        } else {
            identity = .failure(DaemonError.malformedResponse("missing owner metadata reply"))
        }
        return Replies(lines: [identity] + rest.suffix(2), userOriginAllowed: userOriginAllowed)
    }

    private static func servesMachineMetadata(_ reply: Result<LineTransport.Response, any Error>) -> Bool {
        guard let response = try? reply.get(),
              let identity = try? WireCoding.decodeResponse(DaemonIdentity.self, from: response) else { return false }
        return identity.app == "cmux-tui" && identity.protocolVersion == 12 && identity.supports("machine-identity-v1")
    }

    private static func fencedMetadata(_ reply: Result<LineTransport.Response, any Error>,
                                       original: Result<LineTransport.Response, any Error>) -> Result<LineTransport.Response, any Error> {
        Result {
            let first = try WireCoding.decodeResponse(DaemonIdentity.self, from: original.get())
            let response = try reply.get()
            let enriched = try WireCoding.decodeResponse(DaemonIdentity.self, from: response)
            guard enriched.app == first.app, enriched.protocolVersion == first.protocolVersion,
                  enriched.generation == first.generation, enriched.sessionID == first.sessionID else {
                throw DaemonError.malformedResponse("identity changed during owner metadata negotiation")
            }
            return response
        }
    }

    /// Step 2 of `client-hello` when step 1 returned a nonce and the app
    /// holds an install key; nil otherwise (an older daemon answers step 1
    /// with an error, which only leaves the connection unverified).
    static func helloProof(_ hello: ClientHelloIdentity,
                           start: Result<LineTransport.Response, any Error>) -> ClientHelloProofRequest? {
        guard let key = hello.installKey, let response = try? start.get(),
              let nonce = (try? WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: response))?.nonce,
              let proof = key.proof(nonceHex: nonce) else { return nil }
        return ClientHelloProofRequest(installID: key.installID, proof: proof)
    }
}
