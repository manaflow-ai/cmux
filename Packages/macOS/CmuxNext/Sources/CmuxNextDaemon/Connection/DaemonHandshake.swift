import CmuxNextCompat
#if canImport(os)
import os
#endif

/// Validates one transport before its immutable ready session is admitted.
struct DaemonHandshake {
    let configuration: DaemonConnectionConfiguration
    let logger: Logger

    func run(on transport: LineTransport) async throws -> (DaemonIdentity, userOriginAllowed: Bool) {
        if configuration.role == .pageRelay { return (try await PageRelayHandshake.run(transport, configuration: configuration), false) }
        let handshake = await HandshakeLines.send(transport, configuration: configuration, logger: logger)
        let replies = handshake.lines
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: replies[0].get())
        DaemonLaunchTimings.shared.mark("daemon.identify_end")
        guard identity.app == "cmux-tui" else {
            transport.close()
            throw DaemonError.wrongApp(identity.app)
        }
        guard identity.protocolVersion == 12 else {
            transport.close()
            throw DaemonError.unsupportedProtocol(identity.protocolVersion)
        }
        let missing = configuration.requiredCapabilities.filter { !identity.supports($0) }
        guard missing.isEmpty else {
            transport.close()
            throw DaemonError.missingCapabilities(missing)
        }
        _ = try (replies[1].get(), replies[2].get())
        return (identity, handshake.userOriginAllowed)
    }

}
