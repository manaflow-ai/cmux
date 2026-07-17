import CmuxCore
import Dispatch
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteDaemonProxyTunnel file RPCs", .serialized)
struct RemoteDaemonProxyTunnelFileTests {
    @Test("file RPC I/O does not hold the tunnel state queue")
    func fileRPCReleasesTunnelQueue() {
        let rpc = TestPTYLifecycleRPCClient()
        let tunnel = makeTunnel(rpc: rpc)
        defer {
            rpc.releaseFileStat()
            tunnel.stop()
        }
        let operationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? tunnel.statFile(path: "/remote/project/.cmux/dock.json", deadline: .now() + 2)
            operationFinished.signal()
        }
        #expect(rpc.waitForFileStatStart(timeout: .now() + 1) == .success)

        let queueProbeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            tunnel.queue.sync {}
            queueProbeFinished.signal()
        }
        #expect(queueProbeFinished.wait(timeout: .now() + 1) == .success)

        rpc.releaseFileStat()
        #expect(operationFinished.wait(timeout: .now() + 1) == .success)
        let forwardedTimeout = rpc.fileStatTimeout
        #expect(forwardedTimeout != nil)
        #expect((forwardedTimeout ?? 0) > 0)
        #expect((forwardedTimeout ?? 3) <= 2)
    }

    @Test("an expired file deadline fails before daemon I/O")
    func expiredDeadlineSkipsRPC() {
        let rpc = TestPTYLifecycleRPCClient()
        let tunnel = makeTunnel(rpc: rpc)
        defer { tunnel.stop() }

        #expect(throws: (any Error).self) {
            _ = try tunnel.statFile(path: "/remote/project/.cmux/dock.json", deadline: .now())
        }
        #expect(rpc.waitForFileStatStart(timeout: .now()) == .timedOut)
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
}
