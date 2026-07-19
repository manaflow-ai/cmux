import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5734:
// the SSH remote auto-reconnect loop must stop retrying once the host stays
// unreachable, instead of retrying indefinitely, so the user controls when
// reconnection happens. Retargeted from the app's
// WorkspaceRemoteReconnectPolicyTests onto the lifted package types;
// assertions unchanged.
@Suite("RemoteReconnectPolicy")
struct RemoteReconnectPolicyTests {
    private let policy = RemoteReconnectPolicy()

    private func evaluate(
        _ outcome: RemoteHostProbeOutcome,
        previous: Int
    ) -> RemoteReconnectPolicy.Evaluation {
        policy.evaluate(
            outcome: outcome,
            previousConsecutiveUnreachableProbes: previous
        )
    }

    @Test("Reachable host keeps the existing backoff retry loop")
    func reachableHostKeepsRetrying() {
        for previous in [0, 1, policy.maxConsecutiveUnreachableProbes] {
            let evaluation = evaluate(.reachable, previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == 0)
        }
    }

    @Test("Indeterminate probes keep retrying and reset the unreachable streak")
    func indeterminateProbeKeepsRetrying() {
        for previous in [0, 1, policy.maxConsecutiveUnreachableProbes] {
            let evaluation = evaluate(.indeterminate, previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == 0)
        }
    }

    @Test("Unreachable probes below the threshold keep retrying")
    func unreachableBelowThresholdKeepsRetrying() {
        for previous in 0..<(policy.maxConsecutiveUnreachableProbes - 1) {
            let evaluation = evaluate(.unreachable(reason: "connection refused"), previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == previous + 1)
        }
    }

    @Test("Reconnect loop suspends once the host stays unreachable")
    func suspendsAtUnreachableThreshold() {
        var streak = 0
        var decisions: [RemoteReconnectPolicy.Decision] = []
        for _ in 0..<policy.maxConsecutiveUnreachableProbes {
            let evaluation = evaluate(.unreachable(reason: "host timed out"), previous: streak)
            streak = evaluation.consecutiveUnreachableProbes
            decisions.append(evaluation.decision)
        }
        #expect(
            decisions.last == .suspend,
            "The auto-reconnect loop must suspend after \(policy.maxConsecutiveUnreachableProbes) consecutive unreachable probes instead of retrying indefinitely."
        )
        #expect(streak == policy.maxConsecutiveUnreachableProbes)
    }

    @Test("Suspension persists for further unreachable probes past the threshold")
    func staysSuspendedPastThreshold() {
        let evaluation = evaluate(
            .unreachable(reason: "no route to host"),
            previous: policy.maxConsecutiveUnreachableProbes
        )
        #expect(evaluation.decision == .suspend)
    }

    @Test("A reachable probe in between resets the unreachable streak")
    func reachableProbeResetsStreak() {
        var streak = 0
        var sawSuspend = false
        let outcomes: [RemoteHostProbeOutcome] = [
            .unreachable(reason: "timeout"),
            .unreachable(reason: "timeout"),
            .reachable,
            .unreachable(reason: "timeout"),
            .unreachable(reason: "timeout"),
        ]
        for outcome in outcomes {
            let evaluation = evaluate(outcome, previous: streak)
            streak = evaluation.consecutiveUnreachableProbes
            if evaluation.decision == .suspend {
                sawSuspend = true
            }
        }
        #expect(!sawSuspend, "Streaks interrupted by a reachable probe must not suspend the loop.")
        #expect(streak == 2)

        let third = evaluate(.unreachable(reason: "timeout"), previous: streak)
        #expect(
            third.decision == .suspend,
            "Once the streak reaches the threshold again the loop must suspend."
        )
    }

    @Test("System wake re-arms a suspended coordinator with fresh backoff")
    func systemWakeRearmsSuspendedCoordinator() {
        let provider = IntentionalCleanupTestTunnelProvider()
        let coordinator = makeCoordinator(
            broker: RemoteProxyBroker(tunnelProvider: provider)
        )
        defer {
            coordinator.stop()
            coordinator.queue.sync {}
            provider.tunnel.stop()
        }
        coordinator.queue.sync {
            coordinator.isSystemSleeping = true
            coordinator.reconnectRetryCount = 8
            coordinator.consecutiveUnreachableProbeCount = policy.maxConsecutiveUnreachableProbes
            coordinator.reconnectSuspended = true
        }

        coordinator.resetReconnectPolicyAndReconnect(reason: "test wake")
        coordinator.queue.sync {}

        let state = coordinator.queue.sync {
            (
                coordinator.isSystemSleeping,
                coordinator.reconnectRetryCount,
                coordinator.consecutiveUnreachableProbeCount,
                coordinator.reconnectSuspended,
                coordinator.reconnectToken
            )
        }
        #expect(!state.0)
        #expect(state.1 == 1)
        #expect(state.2 == 0)
        #expect(!state.3)
        #expect(state.4 != nil)
    }

    @Test("A ready callback from the released pre-wake proxy lease is ignored")
    func stalePreWakeProxyReadyIsIgnored() {
        let provider = IntentionalCleanupTestTunnelProvider()
        let coordinator = makeCoordinator(
            broker: RemoteProxyBroker(tunnelProvider: provider)
        )
        defer {
            coordinator.stop()
            coordinator.queue.sync {}
            provider.tunnel.stop()
        }
        let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 42_424)

        coordinator.queue.sync {
            coordinator.proxyLeaseGeneration = 2
            coordinator.handleProxyBrokerUpdateLocked(.ready(endpoint), leaseGeneration: 1)
        }

        #expect(coordinator.queue.sync { coordinator.proxyEndpoint } == nil)
    }

    @Test("Wake reset cancels transport-dependent scan work")
    func wakeResetCancelsTransportDependentWork() {
        let provider = IntentionalCleanupTestTunnelProvider()
        let coordinator = makeCoordinator(
            broker: RemoteProxyBroker(tunnelProvider: provider)
        )
        defer {
            coordinator.stop()
            coordinator.queue.sync {}
            provider.tunnel.stop()
        }
        let panelID = UUID()
        coordinator.queue.sync {
            coordinator.isSystemSleeping = true
            coordinator.reconnectSuspended = true
            coordinator.remotePortScanGeneration = 7
            coordinator.remotePortScanBurstActive = true
            coordinator.remotePortScanActiveReason = .command
            coordinator.remotePortScanPendingReason = .refresh
            coordinator.remotePortScanSnapshot.reconcile(
                scannedPorts: [panelID: [22]],
                scannedKeys: [panelID],
                trackedKeys: [panelID],
                completeness: .complete
            )
            coordinator.remotePortPollState.apply(
                observedPorts: [3_000],
                mode: .hostWideDelta,
                completeness: .complete
            )
            coordinator.remotePortPollState.apply(
                observedPorts: [3_000, 8_080],
                mode: .hostWideDelta,
                completeness: .complete
            )
            coordinator.bootstrapRemoteTTYResolved = true
            coordinator.bootstrapRemoteTTYRetryCount = 4
            coordinator.bootstrapRemoteTTYFetchInFlight = true
        }

        coordinator.resetReconnectPolicyAndReconnect(reason: "test wake")
        coordinator.queue.sync {}

        let state = coordinator.queue.sync {
            (
                scanGeneration: coordinator.remotePortScanGeneration,
                scanBurstActive: coordinator.remotePortScanBurstActive,
                scanActiveReason: coordinator.remotePortScanActiveReason,
                scanPendingReason: coordinator.remotePortScanPendingReason,
                scannedPorts: coordinator.remotePortScanSnapshot.snapshot,
                polledPorts: coordinator.remotePortPollState.publishedPorts,
                pollBaseline: coordinator.remotePortPollState.baselinePorts,
                bootstrapTTYResolved: coordinator.bootstrapRemoteTTYResolved,
                bootstrapTTYRetryCount: coordinator.bootstrapRemoteTTYRetryCount,
                bootstrapTTYFetchInFlight: coordinator.bootstrapRemoteTTYFetchInFlight
            )
        }
        #expect(state.scanGeneration == 8)
        #expect(!state.scanBurstActive)
        #expect(state.scanActiveReason == nil)
        #expect(state.scanPendingReason == nil)
        #expect(state.scannedPorts.isEmpty)
        #expect(state.polledPorts.isEmpty)
        #expect(state.pollBaseline == nil)
        #expect(!state.bootstrapTTYResolved)
        #expect(state.bootstrapTTYRetryCount == 0)
        #expect(!state.bootstrapTTYFetchInFlight)
    }

    @Test("Wake leaves a healthy proxy-less Cloud fallback connected")
    func wakeLeavesProxylessCloudFallbackConnected() {
        let provider = IntentionalCleanupTestTunnelProvider()
        let configuration = WorkspaceRemoteConfiguration(
            destination: "vm+cmux@vm-ssh.freestyle.sh",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-default-freestyle-sshd-v1",
            skipDaemonBootstrap: true
        )
        let coordinator = makeCoordinator(
            broker: RemoteProxyBroker(tunnelProvider: provider),
            configuration: configuration
        )
        defer {
            coordinator.stop()
            coordinator.queue.sync {}
            provider.tunnel.stop()
        }
        coordinator.queue.sync {
            coordinator.isSystemSleeping = true
            coordinator.daemonReady = true
            coordinator.proxyEndpoint = nil
        }

        coordinator.resetReconnectPolicyAndReconnect(reason: "test wake")
        coordinator.queue.sync {}

        let state = coordinator.queue.sync {
            (coordinator.reconnectRetryCount, coordinator.reconnectToken, coordinator.daemonReady)
        }
        #expect(state.0 == 0)
        #expect(state.1 == nil)
        #expect(state.2)
    }

    private func makeCoordinator(
        broker: RemoteProxyBroker,
        configuration: WorkspaceRemoteConfiguration? = nil
    ) -> RemoteSessionCoordinator {
        let configuration = configuration ?? WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test"
        )
        return RemoteSessionCoordinator(
            host: IntentionalCleanupTestHost(),
            configuration: configuration,
            proxyBroker: broker,
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: IntentionalCleanupUnusedProcessRunner(),
            reachabilityProbe: IntentionalCleanupNoopReachabilityProbe(),
            relayCommandRewriter: IntentionalCleanupRelayCommandRewriter(),
            buildInfo: IntentionalCleanupBuildInfo(),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@"
            )
        )
    }
}

// The endpoint cases shell out to `/usr/bin/ssh -G` with `Process`/`Pipe`, and
// the TCP-probe cases open real sockets, so this suite lives under the shared
// serialized subprocess parent.
extension RemoteSubprocessTests {
@Suite("RemoteHostReachabilityProbe")
struct RemoteHostReachabilityProbeTests {
    @Test("Parses hostname, port, and proxy fields from ssh -G output")
    func parsesSSHConfigOutput() {
        let output = """
        user nobody
        hostname devbox.internal
        port 2222
        proxyjump bastion@jump.example.com:2200
        addressfamily any
        """
        let resolved = RemoteHostReachabilityProbe.parseSSHConfigOutput(output)
        #expect(resolved.hostName == "devbox.internal")
        #expect(resolved.port == 2222)
        #expect(resolved.proxyJump == "bastion@jump.example.com:2200")
        #expect(resolved.proxyCommand == nil)
    }

    @Test("Treats `proxycommand none` as no proxy")
    func ignoresProxyCommandNone() {
        let resolved = RemoteHostReachabilityProbe.parseSSHConfigOutput(
            "hostname example.com\nport 22\nproxycommand none\n"
        )
        #expect(resolved.proxyCommand == nil)
        #expect(resolved.hostName == "example.com")
    }

    @Test("Parses ProxyJump hop specs")
    func parsesJumpSpecs() {
        let plain = RemoteHostReachabilityProbe.parseJumpSpec("jump.example.com")
        #expect(plain == RemoteHostReachabilityProbe.JumpSpec(
            destination: "jump.example.com", host: "jump.example.com", port: nil
        ))

        let userAndPort = RemoteHostReachabilityProbe.parseJumpSpec("ops@jump.example.com:2200")
        #expect(userAndPort == RemoteHostReachabilityProbe.JumpSpec(
            destination: "ops@jump.example.com", host: "jump.example.com", port: 2200
        ))

        let chained = RemoteHostReachabilityProbe.parseJumpSpec("first.example.com:22,second.example.com")
        #expect(chained?.host == "first.example.com")
        #expect(chained?.port == 22)

        let bracketedV6 = RemoteHostReachabilityProbe.parseJumpSpec("[2001:db8::1]:2200")
        #expect(bracketedV6 == RemoteHostReachabilityProbe.JumpSpec(
            destination: "2001:db8::1", host: "2001:db8::1", port: 2200
        ))

        let bareV6 = RemoteHostReachabilityProbe.parseJumpSpec("2001:db8::1")
        #expect(bareV6?.host == "2001:db8::1")
        #expect(bareV6?.port == nil)
    }

    @Test("ProxyCommand destinations cannot be probed directly")
    func proxyCommandResolvesToNil() {
        // sshConfigFile pins resolution to an empty config so the test stays
        // hermetic against the developer/CI user's ~/.ssh/config.
        let endpoint = RemoteHostReachabilityProbe.resolveEndpoint(
            destination: "nobody@127.0.0.1",
            port: 22,
            identityFile: nil,
            sshOptions: ["ProxyCommand=/usr/bin/nc %h %p"],
            sshConfigFile: "/dev/null"
        )
        #expect(endpoint == nil)
    }

    @Test("Resolves a direct destination's endpoint via ssh -G")
    func resolvesDirectEndpoint() throws {
        let endpoint = RemoteHostReachabilityProbe.resolveEndpoint(
            destination: "nobody@127.0.0.1",
            port: 2222,
            identityFile: nil,
            sshOptions: [],
            sshConfigFile: "/dev/null"
        )
        let resolved = try #require(endpoint)
        #expect(resolved.host == "127.0.0.1")
        #expect(resolved.port == 2222)
    }

    @Test("TCP probe reports a listening endpoint as reachable")
    func tcpProbeReachable() async throws {
        let listener = try BlockingTCPListener()
        defer { listener.close() }
        let outcome = await probeOutcome(host: "127.0.0.1", port: listener.port)
        #expect(outcome == .reachable)
    }

    @Test("TCP probe reports a refused connection as unreachable")
    func tcpProbeRefused() async throws {
        // Bind then close a listener so the port is known-free; the
        // subsequent probe gets an immediate connection refusal.
        let listener = try BlockingTCPListener()
        let refusedPort = listener.port
        listener.close()
        let outcome = await probeOutcome(host: "127.0.0.1", port: refusedPort)
        guard case .unreachable = outcome else {
            Issue.record("Expected .unreachable for a refused port, got \(outcome)")
            return
        }
    }

    private func probeOutcome(host: String, port: Int) async -> RemoteHostProbeOutcome {
        await withCheckedContinuation { continuation in
            RemoteHostReachabilityProbe().probeTCP(
                host: host,
                port: port,
                timeout: 3.0
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }
}
}

/// Minimal loopback TCP listener for probe tests.
private final class BlockingTCPListener {
    let port: Int
    private var fd: Int32

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EMFILE) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(socketFD, 4) == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(.EADDRINUSE)
        }
        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        fd = socketFD
        port = Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        close()
    }
}
