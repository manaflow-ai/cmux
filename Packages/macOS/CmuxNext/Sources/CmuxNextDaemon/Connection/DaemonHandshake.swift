import os

/// Validates one transport before its immutable ready session is admitted.
struct DaemonHandshake {
    let configuration: DaemonConnectionConfiguration
    let logger: Logger

    func run(on transport: LineTransport) async throws -> (DaemonIdentity, userOriginAllowed: Bool) {
        if configuration.role == .pageRelay { return (try await PageRelayHandshake.run(transport, configuration: configuration), false) }
        let handshake = await HandshakeLines.send(transport, configuration: configuration, logger: logger)
        let replies = handshake.lines
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: replies[0].get().line)
        DaemonLaunchTimings.shared.mark("daemon.identify_end")
        guard identity.app == "cmux-tui" else {
            transport.close()
            throw DaemonError.wrongApp(identity.app)
        }
        guard identity.protocolVersion == 12 else {
            throw await refuse(identity, .unsupportedProtocol(identity.protocolVersion), on: transport)
        }
        let missing = configuration.requiredCapabilities.filter { !identity.supports($0) }
        guard missing.isEmpty else {
            throw await refuse(identity, .missingCapabilities(missing), on: transport)
        }
        _ = try (replies[1].get(), replies[2].get())
        return (identity, handshake.userOriginAllowed)
    }

    /// Closes `transport` and returns the error to throw for an incompatible owner. The app's
    /// connection to its local daemon first hands that owner off to the bundled build
    /// (`DaemonConnectionConfiguration.incompatibleOwner`), the same way as an owner of another
    /// build: it exits keeping its terminals and the retry reaches its successor. Only when no
    /// handoff began does `refusal` surface.
    private func refuse(_ identity: DaemonIdentity, _ refusal: DaemonError, on transport: LineTransport) async -> DaemonError {
        defer { transport.close() }
        guard let handOff = configuration.incompatibleOwner, await handOff(identity, transport) else { return refusal }
        logger.info("cmux-tui \(identity.pid) refused (\(refusal.description, privacy: .public)); handing it off to the bundled build")
        return .incompatibleOwnerHandedOff
    }
}
