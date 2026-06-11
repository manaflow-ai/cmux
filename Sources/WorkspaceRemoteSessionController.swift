import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import Observation
import CoreText


final class WorkspaceRemoteSessionController {
#if DEBUG
    // XCTest seam: tests assign this before starting a controller and clear it
    // after disconnect teardown; production/debug app code leaves it nil. The
    // override closure owns synchronization for any captured test-only state.
    nonisolated(unsafe) static var runProcessOverrideForTesting: ((String, [String], Data?, TimeInterval) throws -> (status: Int32, stdout: String, stderr: String))?
    nonisolated(unsafe) static var runProcessReadHandlesDidInstallForTesting: ((FileHandle, FileHandle) -> Void)?
#endif

    enum PortScanKickReason: String {
        case command
        case refresh

        var burstOffsets: [Double] {
            switch self {
            case .command:
                return [0.5, 1.5, 3.0, 5.0, 7.5, 10.0]
            case .refresh:
                return [0.0]
            }
        }

        func merged(with other: Self) -> Self {
            switch (self, other) {
            case (.command, _), (_, .command):
                return .command
            case (.refresh, .refresh):
                return .refresh
            }
        }
    }

    struct RetrySchedule {
        let retry: Int
        let delay: TimeInterval
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    struct RemoteBootstrapState {
        let platform: RemotePlatform
        let homeDirectory: String
        let binaryExists: Bool
    }

    struct RemoteDaemonInstallLocation {
        let relativePath: String
        let absolutePath: String

        var directory: String {
            (absolutePath as NSString).deletingLastPathComponent
        }
    }

    struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    /// The capabilities advertised by the cmuxd-remote baked into the Freestyle snapshot
    /// (scratch/vm-experiments/images/install.sh pins v0.63.2). Keep this in lockstep with
    /// the daemon's `hello` response — if the baked version advertises a new capability,
    /// bump it here too.
    static func bakedVMDaemonHello() -> DaemonHello {
        DaemonHello(
            name: "cmuxd-remote",
            version: "v0.63.2-baked",
            capabilities: [
                "session.basic",
                "session.resize.min",
                "proxy.http_connect",
                "proxy.socks5",
                "proxy.stream",
                "proxy.stream.push",
            ],
            remotePath: "/usr/local/bin/cmuxd-remote"
        )
    }

    let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    let queueKey = DispatchSpecificKey<Void>()
    weak var workspace: Workspace?
    let configuration: WorkspaceRemoteConfiguration
    let controllerID: UUID

    enum RemotePortPollingMode {
        case hostWide
        case hostWideDelta
        case ttyScoped

        var initialDelay: TimeInterval {
            switch self {
            case .hostWide:
                return 0.5
            case .hostWideDelta:
                return 0.5
            case .ttyScoped:
                return 1.0
            }
        }

        var repeatInterval: TimeInterval {
            switch self {
            case .hostWide:
                return 2.0
            case .hostWideDelta:
                return 5.0
            case .ttyScoped:
                return 5.0
            }
        }
    }

    struct PendingPTYBridgeStart {
        let sessionID: String
        let attachmentID: String
        let command: String?
        let requireExisting: Bool
        let isCancelled: () -> Bool
        let completion: (Result<WorkspaceRemotePTYBridgeServer.Endpoint, Error>) -> Void
    }

    var isStopping = false
    var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    var proxyEndpoint: BrowserProxyEndpoint?
    var daemonReady = false
    var daemonBootstrapVersion: String?
    var daemonRemotePath: String?
    var reverseRelayProcess: Process?
    var reverseRelayControlMasterForwardSpec: String?
    var cliRelayServer: WorkspaceRemoteCLIRelayServer?
    var remotePortScanTTYNames: [UUID: String] = [:]
    var remoteScannedPortsByPanel: [UUID: [Int]] = [:]
    var remotePortScanBurstActive = false
    var remotePortScanActiveReason: PortScanKickReason?
    var remotePortScanPendingReason: PortScanKickReason?
    var remotePortScanGeneration: UInt64 = 0
    var remotePortScanCoalesceWorkItem: DispatchWorkItem?
    var remotePortPollTimer: DispatchSourceTimer?
    var remotePortPollMode: RemotePortPollingMode?
    var polledRemotePorts: [Int] = []
    var remotePortPollBaselinePorts: Set<Int>?
    var keepPolledRemotePortsUntilTTYScan = false
    var bootstrapRemoteTTYResolved = false
    var bootstrapRemoteTTYRetryWorkItem: DispatchWorkItem?
    var bootstrapRemoteTTYFetchInFlight = false
    var bootstrapRemoteTTYRetryCount = 0
    var reverseRelayStderrPipe: Pipe?
    var reverseRelayRestartWorkItem: DispatchWorkItem?
    var reverseRelayStderrBuffer = ""
    var reconnectRetryCount = 0
    var reconnectWorkItem: DispatchWorkItem?
    var heartbeatCount: Int = 0
    var connectionAttemptStartedAt: Date?
    var pendingPTYBridgeStarts: [UUID: PendingPTYBridgeStart] = [:]
    var remoteRelayWorkspaceAliases: [UUID: UUID] = [:]
    var remoteRelaySurfaceAliases: [UUID: UUID] = [:]

    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        self.workspace = workspace
        self.configuration = configuration
        self.controllerID = controllerID
        queue.setSpecific(key: queueKey, value: ())
    }

}

