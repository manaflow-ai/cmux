public import Foundation
import CmuxNextWakeups

/// Hands native pasteboard data and the existing authenticated endpoint to
/// the Rust transfer client. Rust owns file IO, the upload and PTY commit.
public struct TerminalFileTransfer: Sendable {
    public let isRemote: Bool
    private let initialTarget: TerminalAttachment.Target
    private let gate: TerminalTargetGate?
    private let policyBlocked: @Sendable () -> Bool
    private let endpoint: @Sendable () async throws -> DaemonEndpoint

    public init(target: TerminalAttachment.Target, gate: TerminalTargetGate?, isRemote: Bool,
                policyBlocked: @escaping @Sendable () -> Bool,
                endpoint: @escaping @Sendable () async throws -> DaemonEndpoint) {
        self.isRemote = isRemote
        initialTarget = target
        self.gate = gate
        self.policyBlocked = policyBlocked
        self.endpoint = endpoint
    }

    /// Both the view and its paste use the target resolved by creation.
    public func target() async throws -> TerminalAttachment.Target {
        guard !policyBlocked() else { throw CancellationError() }
        guard let gate else { return initialTarget }
        guard let resolved = await gate.value() else { throw CancellationError() }
        return resolved
    }

    @concurrent public func paste(files: [String]?, imageData: Data?, imageMIME: String?) async throws {
        guard let terminal = try await target().terminalResourceID else {
            throw DaemonError.endpointBlocked("terminal identity unavailable")
        }
        let endpoint = try await endpoint()
        let terminalID = terminal.rawValue
        let image = imageData.flatMap { data in imageMIME.map { Image(mime: $0, data: data) } }
        let request = Request(socketPath: endpoint.socketPath, bridge: endpoint.bridge.map(Bridge.init),
                              terminalID: terminalID, files: files, image: image)
        let binary = try DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        let outcome = try await AsyncProcess().run(ProcessRequest(
            binary, ["__terminal-paste"], input: try JSONEncoder().encode(request), errorOutput: .separate,
            terminationScope: .processGroup))
        guard outcome.succeeded else { throw DaemonError.endpointBlocked("file paste could not be confirmed") }
    }

    private struct Image: Encodable {
        var mime: String
        var data: Data
    }

    private struct Request: Encodable {
        var socketPath: String
        var bridge: Bridge?
        var terminalID: String
        var files: [String]?
        var image: Image?

        enum CodingKeys: String, CodingKey {
            case socketPath = "socket_path", terminalID = "terminal_id"
            case bridge, files, image
        }
    }

    private struct Bridge: Encodable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var replyTimeoutMs: Int32

        enum CodingKeys: String, CodingKey {
            case executable, arguments, environment
            case replyTimeoutMs = "reply_timeout_ms"
        }

        init(_ bridge: DaemonBridge) {
            executable = bridge.executable
            arguments = bridge.arguments
            environment = bridge.environment
            replyTimeoutMs = bridge.replyTimeoutMs
        }
    }
}
