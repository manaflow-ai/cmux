import CmuxCloudTui
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import os

/// Opens a manual-mirror attach stream and registers this client while the
/// machine is still creating the terminal it will attach to.
///
/// `identify` and `set-client-info` do not depend on the terminal, so a new
/// Cloud pane runs them beside the remote create instead of after it. The
/// session that adopts the result sends only `attach-surface`. The handshake
/// keeps the same order as ``CloudTuiManualMirrorSession``: the attach is
/// never sent before the registration is acknowledged.
@MainActor
final class CloudTuiManualMirrorHandshake {
    /// A connection whose registration the daemon has acknowledged.
    struct Ready {
        let connection: CloudTuiManualIOConnection
        let socketPath: String
        let identified: Bool
        let capabilities: [String]
        /// The first request id the adopting session may use.
        let nextRequestID: UInt64
    }

    private static let identifyRequestID: UInt64 = 1
    private static let clientInfoRequestID: UInt64 = 2

    private let commandBuilder: CloudTuiManualIOCommand
    private let identity: @MainActor () -> TerminalSizingParticipant
    private var task: Task<Ready?, Never>?
    private var taken = false
    // Owned here until a session adopts it; deinit closes an unadopted socket.
    private let pending = OSAllocatedUnfairLock<CloudTuiManualIOConnection?>(initialState: nil)

    init(
        commandBuilder: CloudTuiManualIOCommand = CloudTuiManualIOCommand(),
        identity: @escaping @MainActor () -> TerminalSizingParticipant
    ) {
        self.commandBuilder = commandBuilder
        self.identity = identity
    }

    deinit {
        pending.withLock { $0 }?.close()
    }

    /// Starts the handshake once the link's socket path is known.
    func start(socketPath: @escaping @MainActor () async throws -> String) {
        guard task == nil, !taken else { return }
        task = Task { @MainActor [weak self] in
            guard let path = try? await socketPath(), let self, !Task.isCancelled, !self.taken else { return nil }
            return await self.run(socketPath: path)
        }
    }

    /// Hands the registered connection to one session. Nil means the caller
    /// takes its ordinary path; the handshake never retries on its own.
    func take(socketPath: String) async -> Ready? {
        guard !taken, let task else { return nil }
        taken = true
        let ready = await withTaskCancellationHandler {
            await task.value
        } onCancel: { [pending] in
            pending.withLock { $0 }?.close()
        }
        guard let ready, !Task.isCancelled, ready.socketPath == socketPath else {
            close()
            return nil
        }
        pending.withLock { $0 = nil }
        return ready
    }

    /// Releases an unadopted connection.
    func close() {
        taken = true
        task?.cancel()
        pending.withLock { connection in
            connection?.close()
            connection = nil
        }
    }

    private func run(socketPath: String) async -> Ready? {
        let connection = CloudTuiManualIOConnection(socketPath: socketPath)
        pending.withLock { $0 = connection }
        do { try await connection.start() } catch { return nil }
        // Iterate one frame at a time without a `for await` loop: leaving the
        // loop must not cancel the stream the adopting session reads next.
        var frames = connection.events.makeAsyncIterator()
        connection.send(commandBuilder.identify(requestID: Self.identifyRequestID))
        guard case let .answered(identified, capabilities) = await Self.answer(
            to: Self.identifyRequestID, from: &frames
        ) else { return nil }
        let negotiated = identified ? capabilities : []
        let supportsSizing = Set(negotiated).contains(CloudTerminalSizingRelay.capability)
        connection.send(commandBuilder.setClientInfo(
            name: "cmux cloud terminal",
            kind: "native-mirror",
            identity: supportsSizing ? identity() : nil,
            requestID: Self.clientInfoRequestID
        ))
        guard case .answered = await Self.answer(to: Self.clientInfoRequestID, from: &frames),
              !Task.isCancelled, !taken else { return nil }
        return Ready(
            connection: connection,
            socketPath: socketPath,
            identified: identified,
            capabilities: negotiated,
            nextRequestID: Self.clientInfoRequestID + 1
        )
    }

    private enum Answer {
        case answered(ok: Bool, capabilities: [String])
        case failed
    }

    /// Waits for one response. Any surface frame before the attach means the
    /// stream is not in the state the session expects, so it is not adopted.
    private static func answer(
        to requestID: UInt64,
        from frames: inout AsyncStream<CloudTuiManualIOFrame>.Iterator
    ) async -> Answer {
        while let frame = await frames.next() {
            switch frame {
            case let .response(id, ok, _, capabilities, _, _, _, _) where id == requestID:
                return .answered(ok: ok, capabilities: capabilities)
            case .message:
                continue
            default:
                return .failed
            }
        }
        return .failed
    }
}
