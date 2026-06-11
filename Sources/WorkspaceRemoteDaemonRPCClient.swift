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


final class WorkspaceRemoteDaemonRPCClient {
    static let maxStdoutBufferBytes = 256 * 1024
    static let bakedVMDaemonSocketPath = "/run/cmuxd-remote.sock"
    static let socketForwardStartupGracePeriod: TimeInterval = 0.75
    static let requiredProxyStreamCapability = "proxy.stream.push"
    static let requiredPTYSessionCapability = "pty.session"
    static let requiredPTYSessionTokenCapability = "pty.session.token"
    static let requiredPTYPersistentDaemonCapability = "pty.session.persistent_daemon"
    static let requiredPTYWriteNotificationCapability = "pty.write.notification"

    enum StreamEvent {
        case data(Data)
        case eof(Data)
        case error(String)
    }

    enum PTYEvent {
        case ready
        case data(Data)
        case exit
        case error(String)
    }

    struct StreamSubscription {
        let queue: DispatchQueue
        let handler: (StreamEvent) -> Void
    }

    struct PTYSubscription {
        let queue: DispatchQueue
        let handler: (PTYEvent) -> Void
    }

    let configuration: WorkspaceRemoteConfiguration
    let remotePath: String
    let onUnexpectedTermination: (String) -> Void
    let writeQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.write.\(UUID().uuidString)")
    let stateQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.state.\(UUID().uuidString)")
    let pendingCalls = WorkspaceRemoteDaemonPendingCallRegistry()

    var process: Process?
    var stdinPipe: Pipe?
    var stdoutPipe: Pipe?
    var stderrPipe: Pipe?
    var stdinHandle: FileHandle?
    var stdoutHandle: FileHandle?
    var stderrHandle: FileHandle?
    var webSocketSession: URLSession?
    var webSocketTask: URLSessionWebSocketTask?
    var webSocketDelegate: WebSocketDelegate?
    var isClosed = true
    var shouldReportTermination = true

    var stdoutBuffer = Data()
    var stderrBuffer = ""
    var streamSubscriptions: [String: StreamSubscription] = [:]
    var ptySubscriptions: [String: PTYSubscription] = [:]

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUnexpectedTermination: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.onUnexpectedTermination = onUnexpectedTermination
    }

}

