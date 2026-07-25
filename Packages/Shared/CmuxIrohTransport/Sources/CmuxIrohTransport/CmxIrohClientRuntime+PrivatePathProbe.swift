public import CMUXMobileCore

public extension CmxIrohClientRuntime {
    /// Tests one explicit private address without joining or replacing the live session.
    ///
    /// The registry resolves the exact broker-authenticated Mac EndpointID and
    /// current direct UDP port, then the active endpoint opens a separate QUIC
    /// connection with no relay or alternate direct hints. Because Iroh may
    /// retain other paths for the peer, the selected path must also match the
    /// supplied address before the connection is accepted as proof. The
    /// connection is closed before this method returns.
    ///
    /// - Parameters:
    ///   - request: An Iroh probe request naming the expected Mac device and EndpointID.
    ///   - path: The single device-local address bootstrap to test.
    ///   - timeout: The complete broker-resolution and handshake deadline, capped at five seconds.
    /// - Returns: Authenticated reachability with latency, or a redacted failure reason.
    func probeCustomPrivatePath(
        for request: CmxByteTransportRequest,
        path: CmxIrohCustomPrivatePathBootstrap,
        timeout: Duration = .seconds(5)
    ) async -> CmxIrohPrivatePathProbeResult {
        guard !privatePathProbeActive else {
            return .unreachable(.busy)
        }
        privatePathProbeActive = true
        defer { privatePathProbeActive = false }

        return await CmxIrohPrivatePathProbe(
            dial: { [weak self] in
                guard let self else {
                    throw CmxIrohClientRuntimeError.inactive
                }
                try await self.dialCustomPrivatePathProbe(
                    for: request,
                    path: path
                )
            }
        ).run(timeout: timeout)
    }

    private func dialCustomPrivatePathProbe(
        for request: CmxByteTransportRequest,
        path: CmxIrohCustomPrivatePathBootstrap
    ) async throws {
        guard lifecyclePhase == .active,
              request.sessionPurpose == .probe,
              let provider = registryContextProvider,
              case let .peer(targetIdentity, _) = request.route.endpoint else {
            throw CmxIrohClientRuntimeError.inactive
        }
        let context = try await provider.privatePathProbeContext(
            for: request,
            path: path
        )
        guard context.dialPlan.publicPaths.isEmpty,
              context.dialPlan.privateFallbackPaths.count == 1 else {
            throw CmxIrohRegistryContextError.dialPlanUnavailable
        }
        let endpoint = try await supervisor.activeEndpoint()
        var connection: (any CmxIrohConnection)?
        do {
            let opened = try await endpoint.connect(
                to: CmxIrohEndpointAddress(
                    identity: targetIdentity,
                    pathHints: context.dialPlan.privateFallbackPaths
                ),
                alpn: protocolConfiguration.alpn
            )
            connection = opened
            guard await opened.remoteIdentity() == targetIdentity else {
                throw CmxIrohPrivatePathProbeDialError.wrongPeer
            }
            guard let inspecting = opened as? any CmxIrohConnectionPathInspecting else {
                throw CmxIrohPrivatePathProbeDialError.pathMismatch
            }
            try await CmxIrohPrivatePathSelectedPathVerifier().verify(
                connection: inspecting,
                expectedRemoteAddress: context.dialPlan.privateFallbackPaths[0].value
            )
            await opened.close(
                errorCode: 0,
                reason: "private_path_probe_complete"
            )
        } catch {
            await connection?.close(
                errorCode: 1,
                reason: "private_path_probe_failed"
            )
            throw error
        }
    }
}
