import CmuxCore
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteDaemonProxyTunnel PTY lifecycle", .serialized)
struct RemoteDaemonProxyTunnelPTYBridgeTests {
    @Test("session IDs remain exact while UUID lifecycle IDs canonicalize")
    func lifecycleKeyNormalizationKeepsSessionIdentity() {
        let uppercaseUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let key = RemotePTYLifecycleKey(sessionID: " \(uppercaseUUID) ", lifecycleID: uppercaseUUID)

        #expect(key.sessionID == uppercaseUUID)
        #expect(key.lifecycleID == uppercaseUUID.lowercased())
    }

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

    @Test("cleanup waits for a creating attach before closing the remote PTY")
    func cleanupWaitsForCreatingAttach() throws {
        let rpc = TestPTYLifecycleRPCClient(delaysAttach: true)
        let tunnel = makeTunnel(rpc: rpc)
        defer {
            rpc.releaseAttach()
            tunnel.stop()
        }
        let endpoint = try tunnel.startPTYBridge(
            sessionID: "late-session",
            lifecycleID: "late-lifecycle",
            attachmentID: "surface",
            command: "exec shell",
            requireExisting: false
        )
        let fd = try connect(endpoint)
        defer { Darwin.close(fd) }
        try writeAll(fd, Data("{\"token\":\"\(endpoint.token)\",\"cols\":80,\"rows\":24}\n".utf8))
        #expect(rpc.waitForAttachStart() == .success)

        let cleanupFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { cleanupFinished.signal() }
            try? tunnel.closePTY(sessionID: endpoint.sessionID)
        }

        // Socket EOF is the real signal that cleanup stopped the bridge and
        // reached its attach-completion join.
        #expect(try readToEOF(fd) == 0)
        #expect(rpc.waitForCloseStart(timeout: .now()) == .timedOut)

        rpc.releaseAttach()
        #expect(rpc.waitForCloseStart(timeout: .now() + 2) == .success)
        #expect(cleanupFinished.wait(timeout: .now() + 2) == .success)
        #expect(rpc.closedSessionIDs == [endpoint.sessionID])
    }

    @Test("cleanup deadline rolls back without a late close")
    func cleanupDeadlinePreventsLateClose() throws {
        let rpc = TestPTYLifecycleRPCClient(delaysAttach: true)
        let tunnel = makeTunnel(rpc: rpc)
        defer {
            rpc.releaseAttach()
            tunnel.stop()
        }
        let endpoint = try tunnel.startPTYBridge(
            sessionID: "deadline-session",
            lifecycleID: "deadline-lifecycle",
            attachmentID: "surface",
            command: "exec shell",
            requireExisting: false
        )
        let fd = try connect(endpoint)
        defer { Darwin.close(fd) }
        try writeAll(fd, Data("{\"token\":\"\(endpoint.token)\",\"cols\":80,\"rows\":24}\n".utf8))
        #expect(rpc.waitForAttachStart() == .success)

        do {
            try tunnel.closePTY(sessionID: endpoint.sessionID, deadline: .now())
            Issue.record("expected cleanup deadline error")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.pty")
            #expect(nsError.code == 3)
            #expect(nsError.localizedDescription == "timed out waiting for remote PTY operation")
        }
        #expect(tunnel.ptySessionLifecycle(
            sessionID: endpoint.sessionID,
            lifecycleID: endpoint.lifecycleID
        ) == .active)
        #expect(rpc.closedSessionIDs.isEmpty)

        rpc.releaseAttach()
        #expect(rpc.waitForAttachReturn() == .success)
        #expect(rpc.waitForCloseStart(timeout: .now()) == .timedOut)
        #expect(rpc.closedSessionIDs.isEmpty)
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

    @Test("unused bridge retirement reports lifecycle end")
    func unusedBridgeReportsLifecycleEnd() throws {
        let tunnel = makeTunnel(rpc: TestPTYLifecycleRPCClient())
        let ended = DispatchSemaphore(value: 0)
        _ = try tunnel.startPTYBridge(
            sessionID: "session",
            lifecycleID: "unused",
            attachmentID: "surface",
            command: nil,
            requireExisting: true,
            onLifecycleEnded: { ended.signal() }
        )
        let server = try #require(tunnel.queue.sync { tunnel.ptyBridgeServers.values.first?.server })

        server.stop()

        #expect(ended.wait(timeout: .now() + 2) == .success)
        let counts = tunnel.queue.sync {
            (tunnel.ptyBridgeServers.count, tunnel.ptyLifecycleRegistry.generations.count)
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        tunnel.stop()
    }

    @Test("tunnel replacement reports lifecycle end for an unused bridge")
    func replacementReportsUnusedLifecycleEnd() throws {
        let tunnel = makeTunnel(rpc: TestPTYLifecycleRPCClient())
        let ended = DispatchSemaphore(value: 0)
        _ = try tunnel.startPTYBridge(
            sessionID: "session",
            lifecycleID: "unused",
            attachmentID: "surface",
            command: nil,
            requireExisting: true,
            onLifecycleEnded: { ended.signal() }
        )

        let snapshot = tunnel.stopPreservingPTYLifecycle()

        #expect(ended.wait(timeout: .now() + 2) == .success)
        #expect(snapshot.registry.generations.isEmpty)
    }

    @Test("definitive daemon rejection restores active reconnect eligibility")
    func definitivelyRejectedCleanupRollsBack() throws {
        let rpc = TestPTYLifecycleRPCClient()
        rpc.failClose(with: NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: "pty.close failed (invalid_params): rejected"]
        ))
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

    @Test("ambiguous daemon close failure keeps reconnects closed")
    func ambiguousCleanupFailureStaysClosed() throws {
        let rpc = TestPTYLifecycleRPCClient()
        rpc.failClose(with: NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "daemon RPC timeout waiting for pty.close response"]
        ))
        let tunnel = makeTunnel(rpc: rpc)
        let key = RemotePTYLifecycleKey(sessionID: "target", lifecycleID: "logical-attach")
        try recordReconnectGap(key: key, in: tunnel)
        defer { tunnel.stop() }

        #expect(throws: (any Error).self) { try tunnel.closePTY(sessionID: key.sessionID) }
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

    @Test("cleanup rollback survives rejected reconnect and wrapper end")
    func cleanupRollbackPreservesReconnectEligibility() throws {
        var registry = RemotePTYLifecycleRegistry()
        let rejected = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "rejected")
        let wrapperEnded = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "wrapper-ended")
        let unused = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "unused")
        for key in [rejected, wrapperEnded, unused] {
            try registry.registerBridge(key: key, attachmentID: "surface", bridgeID: UUID())
        }
        for key in [rejected, wrapperEnded] {
            let bridgeID = try #require(registry.generations[key]?.bridgeIDs.first)
            registry.bridgeStopped(key: key, bridgeID: bridgeID, disposition: .acceptedClient)
        }

        let previous = registry.requestIntentionalClose(sessionID: "session")
        let unusedBridgeID = try #require(registry.generations[unused]?.bridgeIDs.first)
        registry.bridgeStopped(key: unused, bridgeID: unusedBridgeID, disposition: .unused)
        #expect(throws: RemotePTYLifecycleError.intentionallyClosed) {
            try registry.registerBridge(
                key: rejected,
                attachmentID: "surface",
                bridgeID: UUID()
            )
        }
        let acknowledgedWrapperEnd = registry.acknowledgeIfKnown(wrapperEnded)
        #expect(acknowledgedWrapperEnd)
        registry.rollbackIntentionalClose(previous)

        for key in [rejected, wrapperEnded, unused] {
            #expect(registry.lifecycle(for: key) == .active)
            try registry.registerBridge(key: key, attachmentID: "surface", bridgeID: UUID())
        }
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
        for key in keys.prefix(2) {
            let bridgeID = UUID()
            try registry.registerBridge(key: key, attachmentID: "attachment", bridgeID: bridgeID)
            registry.bridgeStopped(key: key, bridgeID: bridgeID, disposition: .acceptedClient)
        }

        #expect(registry.generations.count == 2)
        #expect(registry.retiredKeys.isEmpty)
        #expect(registry.lifecycle(for: keys[0]) == .active)
        #expect(registry.lifecycle(for: keys[1]) == .active)
        #expect(throws: RemotePTYLifecycleError.capacityReached) {
            try registry.registerBridge(key: keys[2], attachmentID: "attachment", bridgeID: UUID())
        }

        for key in keys.suffix(3) {
            registry.acknowledge(key)
        }
        #expect(registry.retiredKeys.count == 2)
        #expect(registry.lifecycle(for: keys[2]) == .active)
        #expect(registry.lifecycle(for: keys[3]) == .intentionallyClosed)
        #expect(throws: RemotePTYLifecycleError.intentionallyClosed) {
            try registry.registerBridge(key: keys[3], attachmentID: "attachment", bridgeID: UUID())
        }
    }

    @Test("wrapper-end acknowledgment frees an accepted generation slot")
    func wrapperEndAcknowledgmentFreesCapacity() throws {
        var registry = RemotePTYLifecycleRegistry(generationCapacity: 1, retiredCapacity: 1)
        let ended = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "ended")
        let replacement = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "replacement")
        let bridgeID = UUID()
        try registry.registerBridge(key: ended, attachmentID: "surface", bridgeID: bridgeID)
        registry.bridgeStopped(key: ended, bridgeID: bridgeID, disposition: .acceptedClient)

        registry.acknowledge(ended)
        try registry.registerBridge(key: replacement, attachmentID: "surface", bridgeID: UUID())

        #expect(registry.generations[ended] == nil)
        #expect(registry.generations[replacement] != nil)
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

    @Test("replacement snapshot preserves closed generations until final teardown")
    func replacementSnapshotPreservesClosedGeneration() throws {
        let key = RemotePTYLifecycleKey(sessionID: "session", lifecycleID: "generation")
        let original = makeTunnel(rpc: TestPTYLifecycleRPCClient())
        try recordReconnectGap(key: key, in: original)
        try original.closePTY(sessionID: key.sessionID)

        let snapshot = original.stopPreservingPTYLifecycle()
        let replacement = makeTunnel(rpc: TestPTYLifecycleRPCClient())
        replacement.restorePTYLifecycle(snapshot)
        #expect(replacement.ptySessionLifecycle(
            sessionID: key.sessionID,
            lifecycleID: key.lifecycleID
        ) == .intentionallyClosed)
        #expect(throws: RemotePTYLifecycleError.intentionallyClosed) {
            try replacement.startPTYBridge(
                sessionID: key.sessionID,
                lifecycleID: key.lifecycleID,
                attachmentID: "surface",
                command: nil,
                requireExisting: true
            )
        }

        replacement.stop()
        let counts = replacement.queue.sync {
            (replacement.ptyLifecycleRegistry.generations.count, replacement.ptyLifecycleRegistry.retiredKeys.count)
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
        tunnel.queue.sync { tunnel.rpcClient = rpc }
        return tunnel
    }

    private func connect(_ endpoint: RemotePTYBridgeServer.Endpoint) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(endpoint.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(endpoint.host))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
    }

    private func readToEOF(_ fd: Int32) throws -> Int {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return 0 }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }
}
