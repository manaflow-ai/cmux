internal import Darwin
public import CmuxTerminalBackend
public import Foundation

/// Performs a bounded identify and lightweight authority handshake over the backend socket.
public struct BackendServiceReadinessProbe: BackendServiceReadinessChecking, Sendable {
    private enum AttemptTaskResult: Sendable {
        case readiness(BackendServiceReadiness)
        case deadlineObservedCompletedHandshake
    }

    private let expectedSession: String
    private let policy: BackendHandshakePolicy
    private let timeout: Duration
    private let retryPolicy: BackendServiceReadinessRetryPolicy
    private let expectedUserID: UInt32
    private let clientProcessID: UInt32
    private let trustVerifier: any BackendPeerTrustVerifying
    private let trustVerificationScopeID: UUID
    private let transportFactory: @Sendable () -> any BackendPeerIdentityTransport

    /// Creates a protocol readiness probe for one app-scoped backend.
    ///
    /// - Parameters:
    ///   - descriptor: The expected logical session identity.
    ///   - runtimePaths: Absolute paths shared with launch-agent mode.
    ///   - policy: The protocol range and capabilities required by the app.
    ///   - timeout: One absolute deadline covering every connection attempt,
    ///     retry delay, and protocol handshake.
    ///   - retryPolicy: Backoff used only for transient startup failures.
    ///   - expectedUserID: The effective user required on the peer socket, or
    ///     `nil` to use the current process's effective user.
    ///   - clientProcessID: The app PID that the backend must differ from, or
    ///     `nil` to use the current process identifier.
    ///   - trustedExecutableURL: The backend executable embedded in this app bundle.
    ///   - trustVerifier: An injectable live-process code-signing verifier.
    ///   - transportFactory: An injectable credential-bearing transport factory.
    public init(
        descriptor: BackendServiceDescriptor,
        runtimePaths: BackendServiceRuntimePaths,
        policy: BackendHandshakePolicy = .terminalAuthorityV1,
        timeout: Duration = .seconds(10),
        retryPolicy: BackendServiceReadinessRetryPolicy = .launchdStartup,
        expectedUserID: UInt32? = nil,
        clientProcessID: UInt32? = nil,
        trustedExecutableURL: URL,
        trustVerifier: (any BackendPeerTrustVerifying)? = nil,
        transportFactory: (@Sendable () -> any BackendPeerIdentityTransport)? = nil
    ) {
        precondition(timeout > .zero)
        expectedSession = descriptor.sessionName
        self.policy = policy
        self.timeout = timeout
        self.retryPolicy = retryPolicy
        self.expectedUserID = expectedUserID ?? UInt32(geteuid())
        self.clientProcessID = clientProcessID ?? UInt32(getpid())
        self.trustVerifier = trustVerifier ?? SystemBackendPeerTrustVerifier(
            expectedExecutableURL: trustedExecutableURL
        )
        trustVerificationScopeID = UUID()
        self.transportFactory = transportFactory ?? {
            UnixBackendTransport(path: runtimePaths.socketURL.path)
        }
    }

    /// Connects, validates the negotiated authority, and closes the probe connection.
    ///
    /// A missing launchd socket, refused connection, or connection that closes
    /// during startup is retried with bounded backoff. A trust, protocol, user,
    /// session, or authority error fails immediately.
    ///
    /// - Returns: Identity, compatibility, and revision evidence from the running daemon.
    /// - Throws: A transport, protocol, identity, or deadline error.
    public func checkReadiness() async throws -> BackendServiceReadiness {
        let clock = ContinuousClock()
        let absoluteDeadline = clock.now.advanced(by: timeout)
        var retryDelay = retryPolicy.initialDelay

        while true {
            try Task.checkCancellation()
            guard clock.now < absoluteDeadline else {
                throw BackendServiceReadinessError.timedOut
            }

            do {
                return try await runAttempt(
                    transport: transportFactory(),
                    clock: clock,
                    absoluteDeadline: absoluteDeadline
                )
            } catch {
                if error is CancellationError { throw error }
                if error as? BackendServiceReadinessError == .timedOut {
                    throw BackendServiceReadinessError.timedOut
                }
                guard isRetryableStartupFailure(error) else { throw error }
                guard clock.now < absoluteDeadline else {
                    throw BackendServiceReadinessError.timedOut
                }

                let retryAt = min(clock.now.advanced(by: retryDelay), absoluteDeadline)
                try await clock.sleep(until: retryAt)
                guard clock.now < absoluteDeadline else {
                    throw BackendServiceReadinessError.timedOut
                }
                retryDelay = retryPolicy.nextDelay(after: retryDelay)
            }
        }
    }

    private func runAttempt(
        transport: any BackendPeerIdentityTransport,
        clock: ContinuousClock,
        absoluteDeadline: ContinuousClock.Instant
    ) async throws -> BackendServiceReadiness {
        let client = BackendProtocolClient(transport: transport)
        let deadline = BackendServiceReadinessDeadline()

        return try await withThrowingTaskGroup(of: AttemptTaskResult.self) { group in
            group.addTask {
                do {
                    try await client.connect()
                    let peer = try await transport.peerIdentity()
                    guard peer.userID == expectedUserID else {
                        throw BackendServiceReadinessError.unexpectedPeerUser(
                            expected: expectedUserID,
                            actual: peer.userID
                        )
                    }
                    guard peer.processID != clientProcessID else {
                        throw BackendServiceReadinessError.peerRunsInClientProcess(
                            processID: clientProcessID
                        )
                    }
                    let peerTrust = try await verifyPeerTrust(peer)
                    let identify = try await client.identify()
                    let compatibility = try policy.validate(identify)
                    guard identify.processID == peer.processID else {
                        throw BackendServiceReadinessError.reportedProcessMismatch(
                            kernel: peer.processID,
                            reported: identify.processID
                        )
                    }
                    guard identify.session == expectedSession else {
                        throw BackendServiceReadinessError.unexpectedSession(
                            expected: expectedSession,
                            actual: identify.session
                        )
                    }

                    let health = try await client.health()
                    guard health.authority == identify.authority,
                          health.processID == identify.processID,
                          health.session == identify.session
                    else {
                        throw BackendServiceReadinessError.authorityChanged
                    }
                    guard health.canonicalTopologyRevision
                        >= identify.canonicalTopologyRevision
                    else {
                        throw BackendServiceReadinessError.topologyRevisionRegressed(
                            identify: identify.canonicalTopologyRevision,
                            health: health.canonicalTopologyRevision
                        )
                    }

                    let readiness = BackendServiceReadiness(
                        authority: identify.authority,
                        session: identify.session,
                        processID: peer.processID,
                        userID: peer.userID,
                        peerIdentity: peer,
                        peerTrust: peerTrust,
                        topologyRevision: health.canonicalTopologyRevision,
                        compatibility: compatibility
                    )
                    guard await deadline.complete(
                        clock: clock,
                        before: absoluteDeadline
                    )
                    else {
                        throw BackendServiceReadinessError.timedOut
                    }
                    await client.close()
                    return .readiness(readiness)
                } catch {
                    await client.close()
                    if await deadline.hasExpired() {
                        throw BackendServiceReadinessError.timedOut
                    }
                    throw error
                }
            }
            group.addTask {
                try await clock.sleep(until: absoluteDeadline)
                guard await deadline.expire() else {
                    // The handshake already claimed success before the
                    // deadline. Its connection close may still be suspended,
                    // so this child must not race that success with an error.
                    return .deadlineObservedCompletedHandshake
                }
                // Closing the shared client wakes connect and receive operations
                // before the structured task group waits for their cancellation.
                await client.close()
                throw BackendServiceReadinessError.timedOut
            }

            defer { group.cancelAll() }
            while let result = try await group.next() {
                switch result {
                case let .readiness(readiness):
                    return readiness
                case .deadlineObservedCompletedHandshake:
                    continue
                }
            }
            throw BackendServiceReadinessError.timedOut
        }
    }

    private func isRetryableStartupFailure(
        _ error: any Error,
        underlyingDepth: Int = 0
    ) -> Bool {
        if let protocolError = error as? BackendProtocolError {
            switch protocolError {
            case .connectionClosed, .notConnected:
                return true
            default:
                return false
            }
        }

        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain {
            switch Int32(cocoaError.code) {
            case ENOENT, ECONNREFUSED, ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN:
                return true
            default:
                return false
            }
        }
        if underlyingDepth < 4,
           let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? any Error
        {
            return isRetryableStartupFailure(
                underlying,
                underlyingDepth: underlyingDepth + 1
            )
        }
        return false
    }

    /// Runs synchronous Security.framework inspection on the process-wide,
    /// bounded trust executor. Cancelling this wait ends the probe at its
    /// deadline even if an operating-system call has not returned yet.
    private func verifyPeerTrust(
        _ identity: BackendPeerIdentity
    ) async throws -> BackendPeerTrustEvidence {
        try await BackendPeerTrustVerificationBroker.shared.verify(
            scopeID: trustVerificationScopeID,
            identity: identity,
            using: trustVerifier
        )
    }
}
