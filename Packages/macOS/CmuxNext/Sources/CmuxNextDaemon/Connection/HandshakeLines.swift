import Foundation
import os

/// The connect handshake's request lines (`DaemonHandshake`).
enum HandshakeLines {
    /// The replies of `identify`, `set-client-info` and `subscribe`, in that
    /// order, and whether the daemon accepts origin `user` on the
    /// connection: the last `client-hello` reply's `user_origin_allowed`
    /// (false without a hello, from an older daemon, or on any error).
    struct Replies {
        var lines: [Result<LineTransport.Response, any Error>]
        var userOriginAllowed: Bool
        /// The framed IPC grants and framing (``WireNegotiation``): lines only unless the connection asked for an
        /// upgrade the daemon offered.
        var granted = WireNegotiation.Granted.linesOnly
    }

    /// Sends the handshake. Without `clientHello` the three lines go out in
    /// one round trip; a supporting daemon then supplies explicit owner metadata.
    /// With `clientHello`, step 1 rides with `identify`,
    /// and its proof (step 2, P8 3b-2) leads the second round trip so it
    /// directly follows step 1.
    ///
    /// Framed IPC adds no round trip: the connection echoes what the first `identify` offered
    /// in the `set-client-info` of the second round trip (with `clientHello`), or in a second
    /// `set-client-info` beside the owner metadata (without), and an `identify {revisions}` right after it
    /// tells whether frames were granted, from which schema, and for which methods (``WireNegotiation``).
    static func send(_ transport: LineTransport, configuration: DaemonConnectionConfiguration,
                     logger: Logger) async -> Replies {
        // A streaming connection joins shared sizing as its device; read off the main thread.
        let device = await configuration.streamSizingDevice?()
        let negotiation = WireNegotiation(upgrades: configuration.wireUpgrades, bridged: transport.bridged)
        let subscribe = PipelinedLine(SubscribeRequest(treeEvents: configuration.treeEvents))
        guard let hello = configuration.clientHello else {
            var lines = await transport.pipeline([PipelinedLine(IdentifyRequest()),
                                                  PipelinedLine(clientInfo(configuration, echo: nil, device: device)), subscribe],
                                                 timeout: configuration.requestTimeout)
            let echo = offer(negotiation, in: lines[0])
            let metadata = servesMachineMetadata(lines[0]) ? [PipelinedLine(IdentifyRequest(machineMetadata: true))] : []
            let upgrade = echo.map { upgradeLines(configuration, echo: $0, device: device, on: transport) } ?? []
            guard !(metadata + upgrade).isEmpty else { return Replies(lines: lines, userOriginAllowed: false) }
            let second = await transport.pipeline(metadata + upgrade, timeout: configuration.requestTimeout)
            if !metadata.isEmpty { lines[0] = fencedMetadata(second[0], original: lines[0]) }
            let got = echo.map { granted($0, clientInfo: second.dropFirst(metadata.count).first, revisions: second.last) }
            return Replies(lines: lines, userOriginAllowed: false, granted: got ?? .linesOnly)
        }
        let first = await transport.pipeline([
            PipelinedLine(IdentifyRequest()),
            PipelinedLine(ClientHelloRequest(role: .main, installID: hello.installKey?.installID,
                                             features: hello.features?.request)),
        ], timeout: configuration.requestTimeout)
        let started = (try? first[1].get()).flatMap { try? WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: $0) }
        let proof = helloProof(hello, start: first[1])
        let metadata = servesMachineMetadata(first[0]) ? [PipelinedLine(IdentifyRequest(machineMetadata: true))] : []
        let echo = offer(negotiation, in: first[0])
        if echo?.asksFrames == true { transport.acceptFrames() }
        let setup = [PipelinedLine(clientInfo(configuration, echo: echo, device: device)), subscribe]
        let revisions = echo == nil ? [] : [PipelinedLine(IdentifyRequest(revisions: true))]
        let leading = proof.map { [PipelinedLine($0)] } ?? []
        let rest = await transport.pipeline(leading + metadata + setup + revisions, timeout: configuration.requestTimeout)
        var userOriginAllowed = started?.userOriginAllowed == true
        var featureReport = started?.features
        if proof != nil {
            let proved = (try? rest[0].get()).flatMap { try? WireCoding.decodeResponse(ClientHelloProofRequest.Response.self, from: $0) }
            logger.info("client-hello install-key proof \(proved?.verified == true ? "accepted" : "refused", privacy: .public)")
            userOriginAllowed = proved?.verified == true && proved?.userOriginAllowed == true
            featureReport = proved?.features ?? featureReport
        }
        hello.features?.record(featureReport)
        let identity: Result<LineTransport.Response, any Error>
        if metadata.isEmpty {
            identity = first[0]
        } else if let enriched = rest.dropFirst(leading.count).first {
            identity = fencedMetadata(enriched, original: first[0])
        } else {
            identity = .failure(DaemonError.malformedResponse("missing owner metadata reply"))
        }
        let setupReplies = Array(rest.dropFirst(leading.count + metadata.count).prefix(setup.count))
        let got = echo.map { granted($0, clientInfo: setupReplies.first, revisions: rest.last) }
        return Replies(lines: [identity] + setupReplies, userOriginAllowed: userOriginAllowed, granted: got ?? .linesOnly)
    }

    /// The connection's `set-client-info`: its own capabilities, plus the framed IPC ones of `echo` it does not
    /// echo already (a streaming connection echoes `attach-streams-v1` up front) and, when it asks for frames,
    /// the `api_revision` their grant needs. `device`: the sizing device of a streaming connection, in every
    /// `set-client-info` it sends.
    private static func clientInfo(_ configuration: DaemonConnectionConfiguration, echo: WireNegotiation.Echo?,
                                   device: TerminalSizingDevice?) -> SetClientInfoRequest {
        let own = configuration.handshakeCapabilities
        return SetClientInfoRequest(name: configuration.clientName, kind: "frontend",
                                    capabilities: own + (echo?.capabilities ?? []).filter { !own.contains($0) },
                                    deviceKind: device?.kind, deviceName: device?.name,
                                    apiRevision: echo.flatMap { $0.asksFrames ? $0.apiRevision : nil })
    }

    /// What to echo for `negotiation`, read from the first `identify` reply; nil when nothing is asked or
    /// offered, which leaves the handshake as it was before framed IPC.
    private static func offer(_ negotiation: WireNegotiation,
                              in reply: Result<LineTransport.Response, any Error>) -> WireNegotiation.Echo? {
        guard negotiation.upgrades.asksAny, let response = try? reply.get(),
              let identity = try? WireCoding.decodeResponse(DaemonIdentity.self, from: response),
              identity.app == "cmux-tui", identity.protocolVersion == 12 else { return nil }
        return negotiation.echo(offered: identity)
    }

    /// The second `set-client-info` and the `identify {revisions}` after it, for a connection whose first
    /// `set-client-info` went out before the offer was known. The reader takes frames before they are asked for.
    private static func upgradeLines(_ configuration: DaemonConnectionConfiguration, echo: WireNegotiation.Echo,
                                     device: TerminalSizingDevice?, on transport: LineTransport) -> [PipelinedLine] {
        if echo.asksFrames { transport.acceptFrames() }
        return [PipelinedLine(clientInfo(configuration, echo: echo, device: device)), PipelinedLine(IdentifyRequest(revisions: true))]
    }

    /// What `echo` got, from its `set-client-info` reply and the `identify {revisions}` reply after it.
    private static func granted(_ echo: WireNegotiation.Echo, clientInfo: Result<LineTransport.Response, any Error>?,
                                revisions: Result<LineTransport.Response, any Error>?) -> WireNegotiation.Granted {
        let identity = (try? revisions?.get()).flatMap { try? WireCoding.decodeResponse(DaemonIdentity.self, from: $0) }
        return echo.granted(accepted: (try? clientInfo?.get()) != nil, after: identity)
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
