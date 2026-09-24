import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices

/// Result of a non-interactive command.
public struct SSHExecResult: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    /// `nil` when the server closed without reporting a status.
    public var exitStatus: Int?

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// One authenticated SSH connection. Many channels (shells, exec, forwards,
/// SFTP) multiplex over it.
///
/// Transport is Network.framework through NIOTransportServices, so iOS path
/// changes surface as connection closure rather than silent stalls. A
/// connection can also ride inside another connection's direct-tcpip channel,
/// which is how jump hosts (ProxyJump) work.
public actor SSHConnection {
    public nonisolated let endpoint: SSHEndpoint
    /// The server identity key accepted during the handshake.
    public nonisolated let hostKey: SSHHostKey
    private let channel: any Channel
    private let sshHandler: NIOSSHHandler

    private init(endpoint: SSHEndpoint, hostKey: SSHHostKey, channel: any Channel, sshHandler: NIOSSHHandler) {
        self.endpoint = endpoint
        self.hostKey = hostKey
        self.channel = channel
        self.sshHandler = sshHandler
    }

    /// Future that completes when the connection closes.
    public nonisolated var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

    /// Connects and authenticates.
    ///
    /// - Parameters:
    ///   - via: an already-open connection to tunnel through (jump host).
    ///   - connectTimeout: TCP + handshake budget.
    public static func connect(
        to endpoint: SSHEndpoint,
        credentials: [SSHCredential],
        hostKeyVerifier: any SSHHostKeyVerifier,
        via jump: SSHConnection? = nil,
        connectTimeout: TimeAmount = .seconds(15)
    ) async throws -> SSHConnection {
        let authDelegate = SSHCredentialAuthDelegate(username: endpoint.username, credentials: credentials)
        let hostKeyDelegate = SSHHostKeyAuthDelegate(endpoint: endpoint, verifier: hostKeyVerifier)
        let clientConfiguration = SSHClientConfiguration(userAuthDelegate: authDelegate, serverAuthDelegate: hostKeyDelegate)

        let channel: any Channel
        if let jump {
            channel = try await jump.openDirectTCPIP(host: endpoint.host, port: endpoint.port) { child in
                child.pipeline.addHandler(SSHChannelDataUnwrapper())
            }
        } else {
            channel = try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
                .connectTimeout(connectTimeout)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .connect(host: endpoint.host, port: endpoint.port)
                .get()
        }

        let handshake = channel.eventLoop.makePromise(of: Void.self)
        let sshHandler = try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<NIOSSHHandler> in
            let handler = NIOSSHHandler(
                role: .client(clientConfiguration),
                allocator: channel.allocator,
                inboundChildChannelInitializer: nil
            )
            return channel.pipeline.addHandlers([
                handler,
                SSHHandshakeObserver(promise: handshake),
            ]).map { handler }
        }.get()

        do {
            try await withTimeout(connectTimeout, on: channel.eventLoop, future: handshake.futureResult)
        } catch {
            try? await channel.close()
            if let key = hostKeyDelegate.presentedKey, case SSHConnectionError.hostKeyRejected = error {
                throw SSHConnectionError.hostKeyRejected(.unknown(presented: key))
            }
            throw error
        }
        guard let hostKey = hostKeyDelegate.presentedKey else {
            try? await channel.close()
            throw SSHConnectionError.closed
        }
        return SSHConnection(endpoint: endpoint, hostKey: hostKey, channel: channel, sshHandler: sshHandler)
    }

    /// Closes the connection and every channel on it.
    public func close() async {
        try? await channel.close()
    }

    // MARK: - Session channels

    /// Opens a session channel, optionally with a PTY, then starts `command`
    /// (`exec`), a login shell (`nil`), or a subsystem such as `sftp`.
    public func openSession(
        pty: SSHPTYRequest? = nil,
        environment: [String: String] = [:],
        start: SSHSessionStart
    ) async throws -> SSHSessionChannel {
        let (stream, continuation) = AsyncStream<SSHSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let sessionHandler = SSHSessionChannelHandler(continuation: continuation)
        let child = try await createChannel(type: .session) { child in
            child.pipeline.addHandler(sessionHandler)
        }
        let context = try await child.pipeline.context(handler: sessionHandler).get()
        try await child.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            var chain = child.eventLoop.makeSucceededVoidFuture()
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                // Servers commonly refuse env vars (AcceptEnv); treat as best effort.
                chain = chain.flatMap {
                    sessionHandler.sendRequest(
                        SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: name, value: value),
                        label: "env",
                        context: context
                    ).recover { _ in }
                }
            }
            if let pty {
                chain = chain.flatMap {
                    sessionHandler.sendRequest(
                        SSHChannelRequestEvent.PseudoTerminalRequest(
                            wantReply: true,
                            term: pty.term,
                            terminalCharacterWidth: pty.columns,
                            terminalRowHeight: pty.rows,
                            terminalPixelWidth: pty.pixelWidth,
                            terminalPixelHeight: pty.pixelHeight,
                            terminalModes: SSHTerminalModes([:])
                        ),
                        label: "pty-req",
                        context: context
                    )
                }
            }
            return chain.flatMap {
                switch start {
                case .shell:
                    sessionHandler.sendRequest(SSHChannelRequestEvent.ShellRequest(wantReply: true), label: "shell", context: context)
                case .exec(let command):
                    sessionHandler.sendRequest(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), label: "exec", context: context)
                case .subsystem(let name):
                    sessionHandler.sendRequest(SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true), label: "subsystem", context: context)
                }
            }
        }.get()
        return SSHSessionChannel(channel: child, events: stream)
    }

    /// Runs a command to completion and collects its output.
    public func exec(_ command: String, stdin: Data? = nil) async throws -> SSHExecResult {
        let session = try await openSession(start: .exec(command))
        if let stdin {
            try await session.write(stdin)
            try await session.sendEOF()
        }
        var result = SSHExecResult(stdout: Data(), stderr: Data(), exitStatus: nil)
        for await event in session.events {
            switch event {
            case .stdout(let data): result.stdout.append(data)
            case .stderr(let data): result.stderr.append(data)
            case .exitStatus(let status): result.exitStatus = status
            case .exitSignal: result.exitStatus = result.exitStatus ?? -1
            case .closed: break
            }
        }
        return result
    }

    // MARK: - Forwarding

    /// Opens a `direct-tcpip` channel to `host:port` as seen from the server.
    /// The returned channel carries `SSHChannelData`; `initializer` installs
    /// handlers (e.g. an unwrapper to plain bytes).
    public func openDirectTCPIP(
        host: String,
        port: Int,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let type = SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: originator)
        return try await createChannel(type: .directTCPIP(type), initializer: initializer)
    }

    private func createChannel(
        type: SSHChannelType,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        let sshHandler = sshHandler
        let channel = channel
        return try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<any Channel> in
            let promise = channel.eventLoop.makePromise(of: (any Channel).self)
            sshHandler.createChannel(promise, channelType: type) { child, openedType in
                guard openedType == type else {
                    return child.eventLoop.makeFailedFuture(SSHConnectionError.channelOpenFailed("\(openedType)"))
                }
                return initializer(child)
            }
            return promise.futureResult
        }.get()
    }
}

/// How a session channel starts after optional pty/env requests.
public enum SSHSessionStart: Sendable, Equatable {
    case shell
    case exec(String)
    case subsystem(String)
}

/// Completes the handshake promise once user authentication succeeds, or
/// fails it when the connection errors or closes first.
private final class SSHHandshakeObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private var promise: EventLoopPromise<Void>?

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise?.succeed(())
            promise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise?.fail(error)
        promise = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise?.fail(SSHConnectionError.closed)
        promise = nil
        context.fireChannelInactive()
    }
}

/// Converts `SSHChannelData` to plain `ByteBuffer`s and back, so a
/// direct-tcpip channel can act as a byte transport (jump hosts, forwards).
final class SSHChannelDataUnwrapper: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buffer) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

private func withTimeout(_ timeout: TimeAmount, on eventLoop: any EventLoop, future: EventLoopFuture<Void>) async throws {
    let promise = eventLoop.makePromise(of: Void.self)
    let task = eventLoop.scheduleTask(in: timeout) {
        promise.fail(ChannelError.connectTimeout(timeout))
    }
    future.whenComplete { result in
        task.cancel()
        promise.completeWith(result)
    }
    try await promise.futureResult.get()
}
