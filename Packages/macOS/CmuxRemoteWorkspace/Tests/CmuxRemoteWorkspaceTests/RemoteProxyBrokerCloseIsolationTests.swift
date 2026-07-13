import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteProxyBroker close isolation", .serialized)
struct RemoteProxyBrokerCloseIsolationTests {
    @Test("a blocked PTY close does not hold the shared broker queue")
    func blockedCloseDoesNotBlockList() throws {
        let tunnel = BlockingCloseProxyTunnel()
        let broker = RemoteProxyBroker(
            tunnelProvider: BlockingCloseTunnelProvider(tunnel: tunnel)
        )
        let configuration = Self.configuration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        defer {
            tunnel.releaseClose()
            lease.release()
        }

        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { closeFinished.signal() }
            try? broker.closePTY(
                configuration: configuration,
                sessionID: "session",
                deadline: .distantFuture
            )
        }
        #expect(tunnel.waitForCloseStart() == .success)

        let listFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? broker.listPTY(configuration: configuration)
            listFinished.signal()
        }
        #expect(tunnel.waitForList() == .success)
        #expect(listFinished.wait(timeout: .now() + 2) == .success)

        tunnel.releaseClose()
        #expect(closeFinished.wait(timeout: .now() + 2) == .success)
    }

    @Test("a blocked broker RPC does not block wrapper lifecycle claiming")
    func blockedBrokerRPCDoesNotBlockLifecycleClaim() throws {
        let tunnel = BlockingCloseProxyTunnel(blocksList: true)
        let broker = RemoteProxyBroker(
            tunnelProvider: BlockingCloseTunnelProvider(tunnel: tunnel)
        )
        let configuration = Self.configuration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        defer {
            tunnel.releaseList()
            lease.release()
        }
        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? broker.listPTY(configuration: configuration)
        }
        #expect(tunnel.waitForList() == .success)

        let claimFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = broker.acknowledgePTYLifecycleAfterWrapperEnd(
                sessionID: "session",
                lifecycleID: "generation"
            )
            claimFinished.signal()
        }

        #expect(claimFinished.wait(timeout: .now() + 2) == .success)
    }

    @Test("the last lease keeps a ready tunnel alive until an in-flight RPC returns")
    func lastLeaseReleaseWaitsForInFlightRPC() throws {
        let tunnel = BlockingCloseProxyTunnel(blocksList: true)
        let broker = RemoteProxyBroker(
            tunnelProvider: BlockingCloseTunnelProvider(tunnel: tunnel)
        )
        let configuration = Self.configuration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        defer { tunnel.releaseList() }

        let listFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? broker.listPTY(configuration: configuration)
            listFinished.signal()
        }
        #expect(tunnel.waitForList() == .success)

        lease.release()
        _ = broker.currentPTYLifecycleByAttachment
        #expect(tunnel.waitForStop(timeout: .now()) == .timedOut)

        tunnel.releaseList()
        #expect(listFinished.wait(timeout: .now() + 2) == .success)
        #expect(tunnel.waitForStop() == .success)
        #expect(throws: (any Error).self) {
            try broker.listPTY(configuration: configuration)
        }
    }

    private static func configuration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
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
        )
    }
}
