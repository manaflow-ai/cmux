import CmuxTerminalBackend
@testable import CmuxTerminalBackendService
import Darwin
import Foundation
import Testing

@Suite("Persistent backend readiness handshake", .serialized)
struct BackendServiceReadinessProbeTests {
    private static let daemonID = "11111111-1111-4111-8111-111111111111"
    private static let sessionID = "22222222-2222-4222-8222-222222222222"
    private static let capabilities = [
        "canonical-topology-snapshot-v1",
        "durable-session-identity-v1",
        "presentation-registry-v1",
        "projection-state-reconnect-v1",
        "stable-entity-uuid-v1",
        "topology-resume-v1",
    ]

    @Test("readiness requires identify and an authority-matched health proof")
    func validHandshake() async throws {
        let transport = try makeTransport()
        let readiness = try await makeProbe(transport: transport).checkReadiness()

        #expect(readiness.session == "cmux")
        #expect(readiness.processID == 42)
        #expect(readiness.userID == 501)
        #expect(
            readiness.peerTrust.signingIdentifier
                == SystemBackendPeerTrustVerifier.signingIdentifier
        )
        #expect(readiness.topologyRevision == 8)
        #expect(readiness.authority.daemonInstanceID.description == Self.daemonID)
        #expect(readiness.authority.sessionID.description == Self.sessionID)
        guard case .readOnly(let diagnostic) = readiness.compatibility else {
            Issue.record("expected protocol-v8 readiness to be read-only")
            return
        }
        #expect(diagnostic.negotiatedProtocol == 8)
        #expect(diagnostic.reasons.contains(.protocolTooOld))
        #expect(await transport.isClosed())
    }

    @Test("wrong logical session is rejected")
    func wrongSession() async throws {
        let transport = try makeTransport(session: "other")

        do {
            _ = try await makeProbe(transport: transport).checkReadiness()
            Issue.record("expected session mismatch")
        } catch let error as BackendServiceReadinessError {
            #expect(error == .unexpectedSession(expected: "cmux", actual: "other"))
        }
        #expect(await transport.isClosed())
    }

    @Test("missing launchd socket is retried until the backend appears")
    func delayedSocketAvailability() async throws {
        let missing = try makeTransport(connectBehavior: .posixFailure(ENOENT))
        let ready = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([missing, ready])

        let readiness = try await makeProbe(
            transportFactory: { sequence.next() },
            retryPolicy: .immediateForTesting
        ).checkReadiness()

        #expect(readiness.processID == 42)
        #expect(sequence.remainingCount() == 0)
        #expect(await missing.isClosed())
        #expect(await ready.isClosed())
    }

    @Test("retry backoff cannot extend the single absolute deadline")
    func retryUsesAbsoluteDeadline() async throws {
        let missing = try makeTransport(connectBehavior: .posixFailure(ENOENT))
        let mustNotBeAttempted = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([missing, mustNotBeAttempted])
        let probe = makeProbe(
            transportFactory: { sequence.next() },
            timeout: .milliseconds(20),
            retryPolicy: .init(
                initialDelay: .milliseconds(50),
                maximumDelay: .milliseconds(50)
            )
        )

        await #expect(throws: BackendServiceReadinessError.timedOut) {
            _ = try await probe.checkReadiness()
        }
        #expect(sequence.remainingCount() == 1)
        #expect(await missing.isClosed())
        #expect(!(await mustNotBeAttempted.isClosed()))
    }

    @Test("launchd refusal and restart close are retried under one probe")
    func launchdThrottleAndRestart() async throws {
        let refused = try makeTransport(connectBehavior: .posixFailure(ECONNREFUSED))
        let restarting = try makeTransport(disconnectOnCommand: "identify")
        let ready = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([refused, restarting, ready])

        let readiness = try await makeProbe(
            transportFactory: { sequence.next() },
            retryPolicy: .immediateForTesting
        ).checkReadiness()

        #expect(readiness.processID == 42)
        #expect(sequence.remainingCount() == 0)
        #expect(await refused.isClosed())
        #expect(await restarting.isClosed())
        #expect(await ready.isClosed())
    }

    @Test("a peer exit during handshake reconnects to the replacement")
    func peerExitDuringHandshake() async throws {
        let exited = try makeTransport(disconnectOnCommand: "ping")
        let replacement = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([exited, replacement])

        let readiness = try await makeProbe(
            transportFactory: { sequence.next() },
            retryPolicy: .immediateForTesting
        ).checkReadiness()

        #expect(readiness.topologyRevision == 8)
        #expect(sequence.remainingCount() == 0)
        #expect(await exited.isClosed())
        #expect(await replacement.isClosed())
    }

    @Test("kernel peer must run as the expected effective user")
    func wrongPeerUser() async throws {
        let transport = try makeTransport(peerUserID: 502)
        let unusedValidTransport = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([transport, unusedValidTransport])

        await #expect(
            throws: BackendServiceReadinessError.unexpectedPeerUser(expected: 501, actual: 502)
        ) {
            _ = try await makeProbe(
                transportFactory: { sequence.next() },
                retryPolicy: .immediateForTesting
            ).checkReadiness()
        }
        #expect(sequence.remainingCount() == 1)
        #expect(await transport.isClosed())
        #expect(!(await unusedValidTransport.isClosed()))
    }

    @Test("backend must be a different operating-system process")
    func sameProcess() async throws {
        let transport = try makeTransport(peerProcessID: 99, reportedProcessID: 99)

        await #expect(
            throws: BackendServiceReadinessError.peerRunsInClientProcess(processID: 99)
        ) {
            _ = try await makeProbe(transport: transport, clientProcessID: 99).checkReadiness()
        }
        #expect(await transport.isClosed())
    }

    @Test("self-reported PID must equal the kernel socket peer")
    func falseReportedProcess() async throws {
        let transport = try makeTransport(peerProcessID: 43, reportedProcessID: 42)

        await #expect(
            throws: BackendServiceReadinessError.reportedProcessMismatch(
                kernel: 43,
                reported: 42
            )
        ) {
            _ = try await makeProbe(transport: transport).checkReadiness()
        }
        #expect(await transport.isClosed())
    }

    @Test("kernel identity must belong to the signed backend helper")
    func untrustedPeer() async throws {
        let transport = try makeTransport()
        let unusedValidTransport = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([transport, unusedValidTransport])

        await #expect(
            throws: BackendPeerTrustError.executableUnavailable(
                processID: 42,
                processIDVersion: 1
            )
        ) {
            _ = try await makeProbe(
                transportFactory: { sequence.next() },
                retryPolicy: .immediateForTesting,
                trustVerifier: FixedBackendPeerTrustVerifier(shouldReject: true)
            ).checkReadiness()
        }
        #expect(sequence.remainingCount() == 1)
        #expect(await transport.isClosed())
        #expect(!(await unusedValidTransport.isClosed()))
    }

    @Test("missing terminal-authority capability stays connected read-only")
    func missingCapability() async throws {
        let transport = try makeTransport(
            capabilities: Self.capabilities.filter { $0 != "topology-resume-v1" }
        )
        let unusedValidTransport = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([transport, unusedValidTransport])

        let readiness = try await makeProbe(
            transportFactory: { sequence.next() },
            retryPolicy: .immediateForTesting
        ).checkReadiness()
        guard case .readOnly(let diagnostic) = readiness.compatibility else {
            Issue.record("expected missing capabilities to produce read-only readiness")
            return
        }
        #expect(diagnostic.reasons.contains(.protocolTooOld))
        #expect(diagnostic.reasons.contains(.missingCapabilities))
        #expect(diagnostic.missingCapabilities.contains("topology-resume-v1"))
        #expect(diagnostic.upgradeAction == .updateCmux)
        #expect(sequence.remainingCount() == 1)
        #expect(await transport.isClosed())
        #expect(!(await unusedValidTransport.isClosed()))
    }

    @Test("snapshot authority change is rejected")
    func authorityChange() async throws {
        let transport = try makeTransport(
            healthDaemonID: "33333333-3333-4333-8333-333333333333"
        )
        let unusedValidTransport = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([transport, unusedValidTransport])

        await #expect(throws: BackendServiceReadinessError.authorityChanged) {
            _ = try await makeProbe(
                transportFactory: { sequence.next() },
                retryPolicy: .immediateForTesting
            ).checkReadiness()
        }
        #expect(sequence.remainingCount() == 1)
        #expect(await transport.isClosed())
        #expect(!(await unusedValidTransport.isClosed()))
    }

    @Test("snapshot revision cannot move behind identify")
    func revisionRegression() async throws {
        let transport = try makeTransport(identifyRevision: 9, healthRevision: 8)

        await #expect(
            throws: BackendServiceReadinessError.topologyRevisionRegressed(
                identify: 9,
                health: 8
            )
        ) {
            _ = try await makeProbe(transport: transport).checkReadiness()
        }
        #expect(await transport.isClosed())
    }

    @Test("unresponsive transport is closed at the bounded deadline")
    func boundedDeadline() async throws {
        let transport = try makeTransport(responds: false)
        let probe = makeProbe(transport: transport, timeout: .milliseconds(20))

        await #expect(throws: BackendServiceReadinessError.timedOut) {
            _ = try await probe.checkReadiness()
        }
        #expect(await transport.isClosed())
    }

    @Test("completion claimed before the deadline survives a blocked close")
    func completedHandshakeWinsWhileClosing() async throws {
        let transport = try makeTransport(blocksOnClose: true)
        let probe = makeProbe(transport: transport, timeout: .milliseconds(50))
        let readinessTask = Task {
            try await probe.checkReadiness()
        }

        await transport.waitUntilCloseStarts()
        try await Task.sleep(for: .milliseconds(75))
        await transport.releaseClose()

        let readiness = try await readinessTask.value
        #expect(readiness.processID == 42)
        #expect(await transport.isClosed())
    }

    @Test("a blocked trust verifier cannot extend deadlines or spawn followers")
    func blockedTrustVerifierIsBounded() async throws {
        let firstTransport = try makeTransport()
        let secondTransport = try makeTransport()
        let queuedTransport = try makeTransport()
        let recoveredTransport = try makeTransport()
        let sequence = BackendServiceProbeTransportSequence([firstTransport, secondTransport])
        let trustVerifier = BlockingBackendPeerTrustVerifier()
        let probe = makeProbe(
            transportFactory: { sequence.next() },
            timeout: .milliseconds(100),
            trustVerifier: trustVerifier
        )
        let separatelyScopedProbe = makeProbe(
            transport: queuedTransport,
            timeout: .milliseconds(100),
            trustVerifier: trustVerifier
        )
        let failsafe = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            trustVerifier.release()
        }
        defer {
            failsafe.cancel()
            trustVerifier.release()
        }
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: BackendServiceReadinessError.timedOut) {
            _ = try await probe.checkReadiness()
        }
        await #expect(throws: BackendServiceReadinessError.timedOut) {
            _ = try await probe.checkReadiness()
        }
        await #expect(throws: BackendServiceReadinessError.timedOut) {
            _ = try await separatelyScopedProbe.checkReadiness()
        }

        #expect(started.duration(to: clock.now) < .milliseconds(500))
        #expect(trustVerifier.invocationCount == 1)
        #expect(await firstTransport.isClosed())
        #expect(await secondTransport.isClosed())
        #expect(await queuedTransport.isClosed())

        // One signal releases the single wedged call. The second allows the
        // next real check to finish. If either cancelled queued check survived,
        // it would consume that signal and strand this recovery probe.
        trustVerifier.release()
        trustVerifier.release()
        let readiness = try await makeProbe(
            transport: recoveredTransport,
            trustVerifier: trustVerifier
        ).checkReadiness()
        #expect(readiness.processID == 42)
        #expect(trustVerifier.invocationCount == 2)
        #expect(await recoveredTransport.isClosed())
    }

    @Test("deadline closes a transport stuck while connecting")
    func boundedConnectDeadline() async throws {
        let transport = try makeTransport(responds: false, connectBehavior: .block)
        let probe = makeProbe(transport: transport, timeout: .milliseconds(20))

        await #expect(throws: BackendServiceReadinessError.timedOut) {
            _ = try await probe.checkReadiness()
        }
        #expect(await transport.isClosed())
    }

    private func makeProbe(
        transport: BackendServiceProbeTransport,
        timeout: Duration = .seconds(1),
        clientProcessID: UInt32 = 99,
        trustVerifier: any BackendPeerTrustVerifying = FixedBackendPeerTrustVerifier()
    ) -> BackendServiceReadinessProbe {
        let descriptor = BackendServiceDescriptor.production
        let paths = BackendServiceRuntimePaths(
            descriptor: descriptor,
            userID: 501,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        return BackendServiceReadinessProbe(
            descriptor: descriptor,
            runtimePaths: paths,
            timeout: timeout,
            expectedUserID: 501,
            clientProcessID: clientProcessID,
            trustVerifier: trustVerifier,
            transportFactory: { transport }
        )
    }

    private func makeProbe(
        transportFactory: @escaping @Sendable () -> any BackendPeerIdentityTransport,
        timeout: Duration = .seconds(1),
        retryPolicy: BackendServiceReadinessRetryPolicy = .launchdStartup,
        clientProcessID: UInt32 = 99,
        trustVerifier: any BackendPeerTrustVerifying = FixedBackendPeerTrustVerifier()
    ) -> BackendServiceReadinessProbe {
        let descriptor = BackendServiceDescriptor.production
        let paths = BackendServiceRuntimePaths(
            descriptor: descriptor,
            userID: 501,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        return BackendServiceReadinessProbe(
            descriptor: descriptor,
            runtimePaths: paths,
            timeout: timeout,
            retryPolicy: retryPolicy,
            expectedUserID: 501,
            clientProcessID: clientProcessID,
            trustVerifier: trustVerifier,
            transportFactory: transportFactory
        )
    }

    private func makeTransport(
        session: String = "cmux",
        capabilities: [String] = Self.capabilities,
        identifyRevision: UInt64 = 7,
        healthRevision: UInt64 = 8,
        healthDaemonID: String = Self.daemonID,
        responds: Bool = true,
        connectBehavior: BackendServiceProbeConnectBehavior = .succeed,
        disconnectOnCommand: String? = nil,
        blocksOnClose: Bool = false,
        peerProcessID: UInt32 = 42,
        peerUserID: UInt32 = 501,
        reportedProcessID: UInt32 = 42
    ) throws -> BackendServiceProbeTransport {
        let identify = try JSONSerialization.data(
            withJSONObject: [
                "app": "cmux-tui",
                "version": "0.1.0",
                "protocol": 8,
                "protocol_min": 8,
                "protocol_max": 8,
                "capabilities": capabilities,
                "session": session,
                "daemon_instance_id": Self.daemonID,
                "session_id": Self.sessionID,
                "topology_revision": identifyRevision,
                "canonical_topology_revision": identifyRevision,
                "pid": reportedProcessID,
            ],
            options: [.sortedKeys]
        )
        let health = try JSONSerialization.data(
            withJSONObject: [
                "version": "0.1.0",
                "protocol": 8,
                "protocol_min": 8,
                "protocol_max": 8,
                "capabilities": capabilities,
                "session": session,
                "daemon_instance_id": healthDaemonID,
                "session_id": Self.sessionID,
                "canonical_topology_revision": healthRevision,
                "pid": reportedProcessID,
            ],
            options: [.sortedKeys]
        )
        return BackendServiceProbeTransport(
            payloads: [
                "identify": identify,
                "ping": health,
            ],
            responds: responds,
            connectBehavior: connectBehavior,
            disconnectOnCommand: disconnectOnCommand,
            blocksOnClose: blocksOnClose,
            peerIdentity: BackendPeerIdentity(
                processID: peerProcessID,
                userID: peerUserID,
                auditToken: testBackendAuditToken(
                    processID: peerProcessID,
                    userID: peerUserID
                )
            )
        )
    }
}

private extension BackendServiceReadinessProbe {
    func checkReadiness() async throws -> BackendServiceReadiness {
        let directory = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support/cmux/terminal-backend/test/versions/\(String(repeating: "a", count: 64))",
            isDirectory: true
        )
        return try await checkReadiness(
            trustedPair: BackendServiceInstalledPair(
                buildID: String(repeating: "a", count: 64),
                installationDirectoryURL: directory,
                backendExecutableURL: directory.appendingPathComponent("cmux-terminal-backend"),
                rendererExecutableURL: directory.appendingPathComponent("cmux-terminal-renderer"),
                manifestURL: directory.appendingPathComponent("pair-manifest.json")
            )
        )
    }
}
