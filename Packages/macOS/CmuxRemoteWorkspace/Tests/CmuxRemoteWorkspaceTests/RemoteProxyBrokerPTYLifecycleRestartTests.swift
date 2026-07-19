import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

extension FakeProxyTunnel {
    func ptySessionLifecycle(sessionID: String, lifecycleID: String) -> RemotePTYSessionLifecycle {
        record("ptySessionLifecycle", [sessionID, lifecycleID])
        return lock.withLock {
            ptyLifecycleRegistry.lifecycle(
                for: RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
    }

    func acknowledgePTYLifecycle(sessionID: String, lifecycleID: String) {
        record("acknowledgePTYLifecycle", [sessionID, lifecycleID])
        lock.withLock {
            ptyLifecycleRegistry.acknowledge(
                RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
    }

    func acknowledgePTYLifecycleIfKnown(sessionID: String, lifecycleID: String) -> Bool {
        record("acknowledgePTYLifecycleIfKnown", [sessionID, lifecycleID])
        return lock.withLock {
            ptyLifecycleRegistry.acknowledgeIfKnown(
                RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
    }

    func reportLifecycleEnded(sessionID: String, lifecycleID: String) {
        let callback = lock.withLock {
            lifecycleEndCallbacks.removeValue(
                forKey: RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
        callback?()
    }
}

@Suite("RemoteProxyBroker PTY lifecycle restart", .serialized)
struct RemoteProxyBrokerPTYLifecycleRestartTests {
    @Test("intentional-close lifecycle survives a failed automatic tunnel replacement")
    func intentionalCloseSurvivesTunnelReplacement() throws {
        let provider = FakeTunnelProvider()
        let clock = ManualRetryClock()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: clock)
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        try broker.closePTY(
            configuration: configuration,
            sessionID: "session",
            deadline: .distantFuture
        )
        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation"
        ) == .intentionallyClosed)

        provider.failNextStarts(1)
        let fatalError = try #require(provider.fatalErrorCallback(at: 0))
        fatalError("transport died")
        #expect(clock.waitForSleeps(1))
        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation"
        ) == .intentionallyClosed)
        clock.fireOldestSleep()
        #expect(clock.waitForSleeps(2))
        clock.fireOldestSleep()
        let deadline = Date().addingTimeInterval(5.0)
        while provider.tunnels.count < 3 && Date() < deadline { usleep(10_000) }
        #expect(provider.tunnels.count == 3)

        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation"
        ) == .intentionallyClosed)
        #expect(throws: RemotePTYLifecycleError.self) {
            try broker.startPTYBridge(
                configuration: configuration,
                sessionID: "session",
                lifecycleID: "generation",
                attachmentID: "surface",
                command: nil,
                requireExisting: true
            )
        }
    }

    @Test("wrapper end retires a generation while tunnel replacement is pending")
    func wrapperEndRetiresReplacementSnapshot() throws {
        let provider = FakeTunnelProvider()
        let clock = ManualRetryClock()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: clock)
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "UPPERCASE-SESSION",
            lifecycleID: "generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        let fatalError = try #require(provider.fatalErrorCallback(at: 0))
        fatalError("transport died")
        #expect(clock.waitForSleeps(1))

        broker.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "UPPERCASE-SESSION",
            lifecycleID: "generation"
        )
        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "UPPERCASE-SESSION",
            lifecycleID: "generation"
        ) == .intentionallyClosed)
        clock.fireOldestSleep()
        let deadline = Date().addingTimeInterval(5.0)
        while provider.tunnels.count < 2 && Date() < deadline { usleep(10_000) }

        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "UPPERCASE-SESSION",
            lifecycleID: "generation"
        ) == .intentionallyClosed)
    }

    @Test("wrapper retirement finds its owner without tombstoning unrelated generations")
    func wrapperRetirementFindsOnlyKnownGeneration() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "known",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        broker.acknowledgePTYLifecycleAfterWrapperEnd(sessionID: "session", lifecycleID: "known")
        broker.acknowledgePTYLifecycleAfterWrapperEnd(sessionID: "session", lifecycleID: "unknown")

        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "known"
        ) == .intentionallyClosed)
        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "unknown",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
    }

    @Test("stale wrapper end cannot claim a newer generation on the same attachment")
    func staleWrapperEndDoesNotClaimNewAttachmentGeneration() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        for lifecycleID in ["old-generation", "new-generation"] {
            _ = try broker.startPTYBridge(
                configuration: configuration,
                sessionID: "session",
                lifecycleID: lifecycleID,
                attachmentID: "surface",
                command: nil,
                requireExisting: true
            )
        }

        let oldGenerationWasCurrent = broker.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "session",
            lifecycleID: "old-generation"
        )
        let newGenerationWasCurrent = broker.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "session",
            lifecycleID: "new-generation"
        )

        #expect(!oldGenerationWasCurrent)
        #expect(newGenerationWasCurrent)
    }

    @Test("ended lifecycle removes its broker owner index")
    func endedLifecycleRemovesOwnerIndex() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "unused",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        let tunnel = try #require(provider.tunnels.first)
        tunnel.reportLifecycleEnded(sessionID: "session", lifecycleID: "unused")
        _ = try broker.listPTY(configuration: configuration)

        let generationWasCurrent = broker.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "session",
            lifecycleID: "unused"
        )
        _ = try broker.listPTY(configuration: configuration)

        #expect(generationWasCurrent)
        #expect(tunnel.ptyCalls.contains { $0.name == "acknowledgePTYLifecycleIfKnown" })
        #expect(!broker.acknowledgePTYLifecycleAfterWrapperEnd(sessionID: "session", lifecycleID: "unused"))
    }

    @Test("explicit acknowledgement removes its attachment generation index")
    func explicitAcknowledgementRemovesAttachmentGenerationIndex() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        #expect(broker.currentPTYLifecycleByAttachment.count == 1)

        try broker.acknowledgePTYLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation"
        )

        #expect(broker.currentPTYLifecycleByAttachment.isEmpty)
    }

    @Test("ended lifecycle reconciliation state stays bounded")
    func endedLifecycleReconciliationStateStaysBounded() {
        var registry = RemotePTYEndedLifecycleRegistry()
        for index in 0..<(RemotePTYEndedLifecycleRegistry.capacity + 10) {
            registry.record(
                RemotePTYLifecycleKey(sessionID: "session-\(index)", lifecycleID: "generation-\(index)"),
                transportKey: "transport",
                attachmentKey: RemotePTYAttachmentKey(transportKey: "transport", attachmentID: "surface-\(index)")
            )
        }

        #expect(registry.count == RemotePTYEndedLifecycleRegistry.capacity)
        #expect(registry.take(RemotePTYLifecycleKey(sessionID: "session-0", lifecycleID: "generation-0")) == nil)
        #expect(registry.take(RemotePTYLifecycleKey(sessionID: "session-265", lifecycleID: "generation-265")) != nil)
    }

    @Test("newer ended attachment generation supersedes its predecessor")
    func newerEndedAttachmentGenerationSupersedesPredecessor() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }
        let tunnel = try #require(provider.tunnels.first)

        for lifecycleID in ["old-generation", "new-generation"] {
            _ = try broker.startPTYBridge(
                configuration: configuration,
                sessionID: "session",
                lifecycleID: lifecycleID,
                attachmentID: "surface",
                command: nil,
                requireExisting: true
            )
            tunnel.reportLifecycleEnded(sessionID: "session", lifecycleID: lifecycleID)
            _ = try broker.listPTY(configuration: configuration)
        }

        #expect(!broker.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "session",
            lifecycleID: "old-generation"
        ))
        #expect(broker.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "session",
            lifecycleID: "new-generation"
        ))
    }

    @Test("newer acknowledged attachment generation supersedes an ended predecessor")
    func newerAcknowledgedAttachmentGenerationSupersedesEndedPredecessor() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }
        let tunnel = try #require(provider.tunnels.first)

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "old-generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        tunnel.reportLifecycleEnded(sessionID: "session", lifecycleID: "old-generation")
        _ = try broker.listPTY(configuration: configuration)

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "new-generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        try broker.acknowledgePTYLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "new-generation"
        )

        #expect(!broker.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "session",
            lifecycleID: "old-generation"
        ))
    }

    @Test("forced local proxy port is used verbatim")
    func forcedLocalProxyPort() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration(localProxyPort: 45_678)
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        #expect(try #require(provider.tunnels.first).localPort == 45_678)
    }

    private func makeConfiguration(localProxyPort: Int? = nil) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "test@example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: localProxyPort,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
    }
}
