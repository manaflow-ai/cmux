import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteDaemonProxyTunnel PTY lifecycle", .serialized)
struct RemoteDaemonProxyTunnelPTYBridgeTests {
    @Test("cleanup during a reconnect gap blocks both bridge start modes")
    func cleanupDuringReconnectGapBlocksRespawn() throws {
        let rpc = TestPTYLifecycleRPCClient()
        let tunnel = makeTunnel(rpc: rpc)
        let key = RemotePTYLifecycleKey(sessionID: "target", lifecycleID: "logical-attach")
        try recordReconnectGap(key: key, in: tunnel)
        defer { tunnel.stop() }

        try tunnel.closePTY(sessionID: key.sessionID)

        #expect(tunnel.ptySessionLifecycle(
            sessionID: key.sessionID,
            lifecycleID: key.lifecycleID
        ) == .intentionallyClosed)
        for requireExisting in [true, false] {
            #expect(throws: RemotePTYLifecycleError.self) {
                try tunnel.startPTYBridge(
                    sessionID: key.sessionID,
                    lifecycleID: key.lifecycleID,
                    attachmentID: "surface",
                    command: nil,
                    requireExisting: requireExisting
                )
            }
        }
        #expect(tunnel.queue.sync { tunnel.ptyLifecycleRegistry.generations[key] == nil })
        #expect(tunnel.queue.sync { tunnel.ptyLifecycleRegistry.retiredKeys.contains(key) })
        #expect(rpc.closedSessionIDs == [key.sessionID])
    }

    @Test("acknowledged closed generations remain tombstoned against stale retry")
    func acknowledgedGenerationRejectsOldRetry() throws {
        let tunnel = makeTunnel(rpc: TestPTYLifecycleRPCClient())
        let key = RemotePTYLifecycleKey(sessionID: "target", lifecycleID: "logical-attach")
        try recordReconnectGap(key: key, in: tunnel)
        defer { tunnel.stop() }
        try tunnel.closePTY(sessionID: key.sessionID)

        tunnel.acknowledgePTYLifecycle(sessionID: key.sessionID, lifecycleID: key.lifecycleID)

        #expect(tunnel.ptySessionLifecycle(
            sessionID: key.sessionID,
            lifecycleID: key.lifecycleID
        ) == .intentionallyClosed)
        #expect(throws: RemotePTYLifecycleError.self) {
            try tunnel.startPTYBridge(
                sessionID: key.sessionID,
                lifecycleID: key.lifecycleID,
                attachmentID: "surface",
                command: nil,
                requireExisting: false
            )
        }
    }

    @Test("daemon close failure restores active reconnect eligibility")
    func failedCleanupRollsBack() throws {
        let rpc = TestPTYLifecycleRPCClient()
        rpc.failClose(with: NSError(domain: "test.close", code: 1))
        let tunnel = makeTunnel(rpc: rpc)
        let key = RemotePTYLifecycleKey(sessionID: "target", lifecycleID: "logical-attach")
        try recordReconnectGap(key: key, in: tunnel)
        defer { tunnel.stop() }

        #expect(throws: (any Error).self) { try tunnel.closePTY(sessionID: key.sessionID) }
        #expect(tunnel.ptySessionLifecycle(
            sessionID: key.sessionID,
            lifecycleID: key.lifecycleID
        ) == .active)
        _ = try tunnel.startPTYBridge(
            sessionID: key.sessionID,
            lifecycleID: key.lifecycleID,
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
    }

    @Test("unused and closed-unused endpoints retire without live generation leaks")
    func unusedGenerationsRetire() throws {
        var registry = RemotePTYLifecycleRegistry()
        let unused = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "unused")
        let closedUnused = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "closed-unused")
        let unusedBridge = UUID()
        let closedBridge = UUID()
        try registry.registerBridge(key: unused, attachmentID: "attachment", bridgeID: unusedBridge)
        registry.bridgeStopped(key: unused, bridgeID: unusedBridge, disposition: .unused)
        try registry.registerBridge(key: closedUnused, attachmentID: "attachment", bridgeID: closedBridge)
        let previous = registry.requestIntentionalClose(sessionID: "session")
        registry.completeIntentionalClose(previous)
        registry.bridgeStopped(key: closedUnused, bridgeID: closedBridge, disposition: .unused)

        #expect(registry.generations.isEmpty)
        #expect(registry.lifecycle(for: unused) == .active)
        #expect(registry.lifecycle(for: closedUnused) == .intentionallyClosed)
    }

    @Test("generation and retired tombstone registries enforce deterministic caps")
    func registryIsBounded() throws {
        var registry = RemotePTYLifecycleRegistry(generationCapacity: 2, retiredCapacity: 2)
        let keys = (0..<5).map {
            RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "generation-\($0)")
        }
        for key in keys {
            let bridgeID = UUID()
            try registry.registerBridge(key: key, attachmentID: "attachment", bridgeID: bridgeID)
            registry.bridgeStopped(key: key, bridgeID: bridgeID, disposition: .acceptedClient)
        }

        #expect(registry.generations.count == 2)
        #expect(registry.retiredKeys.count == 2)
        #expect(registry.lifecycle(for: keys[2]) == .intentionallyClosed)
        #expect(registry.lifecycle(for: keys[0]) == .active)
        #expect(throws: RemotePTYLifecycleError.self) {
            try registry.registerBridge(key: keys[2], attachmentID: "attachment", bridgeID: UUID())
        }
    }

    @Test("tunnel teardown clears active generations and retired tombstones")
    func teardownClearsLifecycleState() throws {
        let tunnel = makeTunnel(rpc: TestPTYLifecycleRPCClient())
        let active = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "active")
        let retired = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "retired")
        try recordReconnectGap(key: active, in: tunnel)
        tunnel.acknowledgePTYLifecycle(sessionID: retired.sessionID, lifecycleID: retired.lifecycleID)

        tunnel.stop()

        let counts = tunnel.queue.sync {
            (tunnel.ptyLifecycleRegistry.generations.count, tunnel.ptyLifecycleRegistry.retiredKeys.count)
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
    }

    private func recordReconnectGap(
        key: RemotePTYLifecycleKey,
        in tunnel: RemoteDaemonProxyTunnel
    ) throws {
        try tunnel.queue.sync {
            let bridgeID = UUID()
            try tunnel.ptyLifecycleRegistry.registerBridge(
                key: key,
                attachmentID: "surface",
                bridgeID: bridgeID
            )
            tunnel.ptyLifecycleRegistry.bridgeStopped(
                key: key,
                bridgeID: bridgeID,
                disposition: .acceptedClient
            )
        }
    }

    private func makeTunnel(rpc: TestPTYLifecycleRPCClient) -> RemoteDaemonProxyTunnel {
        let tunnel = RemoteDaemonProxyTunnel(
            configuration: WorkspaceRemoteConfiguration(
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
                persistentDaemonSlot: nil
            ),
            remotePath: "/remote/cmuxd",
            localPort: 42_424,
            strings: .init(missingPersistentPTYCapability: "", missingRequiredFunctionality: ""),
            ptyBridgeStrings: TestPTYBridgeStrings(),
            onFatalError: { _ in }
        )
        tunnel.queue.sync { tunnel.ptyRPCClient = rpc }
        return tunnel
    }
}
