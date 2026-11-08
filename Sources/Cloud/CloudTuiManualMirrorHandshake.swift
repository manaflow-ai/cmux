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

    /// Shared with the unstructured work and the nonisolated cancel handler.
    /// Abandoning (close, or a cancelled take) is distinct from a session
    /// claiming the result while the registration is still in flight.
    private struct Pending {
        var connection: CloudTuiManualIOConnection?
        var abandoned = false
        var task: Task<Ready?, Never>?

        mutating func abandon() {
            abandoned = true
            connection?.close()
            connection = nil
            task?.cancel()
        }
    }

    private static let identifyRequestID: UInt64 = 1
    private static let clientInfoRequestID: UInt64 = 2

    private let commandBuilder: CloudTuiManualIOCommand
    private let identity: @MainActor () -> TerminalSizingParticipant
    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private var started = false
    private var claimed = false

    init(
        commandBuilder: CloudTuiManualIOCommand = CloudTuiManualIOCommand(),
        identity: @escaping @MainActor () -> TerminalSizingParticipant
    ) {
        self.commandBuilder = commandBuilder
        self.identity = identity
    }

    deinit {
        pending.withLock { $0.abandon() }
    }

    /// Starts the handshake once the link's socket path is known. The work
    /// holds no reference to this object, so an unadopted handshake is
    /// released (and its socket closed) with its reservation.
    func start(socketPath: @escaping @MainActor () async throws -> String) {
        guard !started else { return }
        started = true
        let pending = pending
        let commandBuilder = commandBuilder
        let identity = identity
        let task = Task { @MainActor () -> Ready? in
            guard let path = try? await socketPath(), !Task.isCancelled else { return nil }
            return await Self.run(socketPath: path, pending: pending, commandBuilder: commandBuilder, identity: identity)
        }
        pending.withLock { state in
            if state.abandoned { task.cancel() } else { state.task = task }
        }
    }

    /// Hands the registered connection to one session, waiting for a
    /// registration still in flight. Nil means the caller takes its ordinary
    /// path; the handshake never retries on its own.
    func take(socketPath: String) async -> Ready? {
        guard !claimed else { return nil }
        claimed = true
        guard let task = pending.withLock({ $0.abandoned ? nil : $0.task }) else { return nil }
        let pending = pending
        let ready = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            pending.withLock { $0.abandon() }
        }
        let adopted = pending.withLock { state -> Bool in
            guard let ready, !state.abandoned, ready.socketPath == socketPath else { return false }
            state.connection = nil
            return true
        }
        guard adopted, let ready, !Task.isCancelled else {
            close()
            return nil
        }
        return ready
    }

    /// Releases an unadopted connection and stops a registration in flight.
    func close() {
        claimed = true
        pending.withLock { $0.abandon() }
    }

    private static func run(
        socketPath: String,
        pending: OSAllocatedUnfairLock<Pending>,
        commandBuilder: CloudTuiManualIOCommand,
        identity: @MainActor () -> TerminalSizingParticipant
    ) async -> Ready? {
        let connection = CloudTuiManualIOConnection(socketPath: socketPath)
        let admitted = pending.withLock { state -> Bool in
            guard !state.abandoned else { return false }
            state.connection = connection
            return true
        }
        guard admitted else { return nil }
        do { try await connection.start() } catch { return nil }
        // Iterate one frame at a time without a `for await` loop: leaving the
        // loop must not cancel the stream the adopting session reads next.
        var frames = connection.events.makeAsyncIterator()
        connection.send(commandBuilder.identify(requestID: identifyRequestID))
        guard case let .answered(identified, capabilities) = await answer(
            to: identifyRequestID, from: &frames
        ) else { return nil }
        let negotiated = identified ? capabilities : []
        let supportsSizing = Set(negotiated).contains(CloudTerminalSizingRelay.capability)
        connection.send(commandBuilder.setClientInfo(
            name: "cmux cloud terminal",
            kind: "native-mirror",
            identity: supportsSizing ? identity() : nil,
            requestID: clientInfoRequestID
        ))
        guard case .answered = await answer(to: clientInfoRequestID, from: &frames),
              !Task.isCancelled else { return nil }
        return Ready(
            connection: connection,
            socketPath: socketPath,
            identified: identified,
            capabilities: negotiated,
            nextRequestID: clientInfoRequestID + 1
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
