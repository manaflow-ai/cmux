internal import CmuxRemoteDaemon
internal import Foundation
internal import Network

extension RemotePTYBridgeServer {
    /// The single accepted bridge connection: consumes the handshake line,
    /// attaches to the remote PTY over RPC, then pumps client input to
    /// `pty.write` and PTY output back to the socket, with byte-capped
    /// buffering on both directions (faithful lift of the legacy nested
    /// `WorkspaceRemotePTYBridgeServer.Session`).
    ///
    /// Isolation design: all mutable state is confined to the server's
    /// serial `queue` (Network callbacks start on it; RPC completions and
    /// the rpcQueue hop back onto it). The separate `rpcQueue` preserves the
    /// legacy contract that blocking RPC calls never stall the socket
    /// pump. `@unchecked Sendable` because `@Sendable` Network/RPC/Task
    /// callbacks capture `self`; queue confinement is the safety argument.
    final class Session: @unchecked Sendable {
        private static let maxHandshakeBytes = 4096
        private static let handshakeTimeoutMilliseconds = 30_000
        private static let maxPendingOutputSends = 256
        private static let maxPendingOutputBytes = 4 * 1024 * 1024
        private static let maxPendingInputWrites = 256
        private static let maxPendingInputBytes = 4 * 1024 * 1024

        private let connection: NWConnection
        private let rpcClient: any RemotePTYBridgeRPCClient
        private let sessionID: String
        private let attachmentID: String
        private let command: String?
        private let requireExisting: Bool
        private let token: String
        private let queue: DispatchQueue
        private let rpcQueue = DispatchQueue(label: "com.cmux.remote-ssh.pty-bridge.rpc.\(UUID().uuidString)", qos: .userInitiated)
        private let strings: any RemotePTYBridgeStrings
        private let clock: any RemoteProxyRetryClock
        private let onClose: () -> Void

        private var isClosed = false
        private var isAttaching = false
        private var isAttached = false
        private var handshakeBuffer = Data()
        private var pendingInputBeforeAttach = Data()
        private var pendingInputWrites = 0
        private var pendingInputBytes = 0
        private var pendingOutputSends = 0
        private var pendingOutputBytes = 0
        private var clientInputDidComplete = false
        private var pendingPTYEventsBeforeReady: [RemotePTYBridgeEvent] = []
        private var pendingPTYEventBytesBeforeReady = 0
        private var closeWhenOutputFlushes: (detach: Bool, gracefulOutputClose: Bool)?
        private var handshakeTimeoutTask: Task<Void, Never>?
        private var remoteAttachment: RemotePTYBridgeAttachment?
        private var clientPID: pid_t?
        private var clientProcessExitSource: (any DispatchSourceProcess)?

        init(
            connection: NWConnection,
            rpcClient: any RemotePTYBridgeRPCClient,
            sessionID: String,
            attachmentID: String,
            command: String?,
            requireExisting: Bool,
            token: String,
            queue: DispatchQueue,
            strings: any RemotePTYBridgeStrings,
            clock: any RemoteProxyRetryClock,
            onClose: @escaping () -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.sessionID = sessionID
            self.attachmentID = attachmentID
            self.command = command
            self.requireExisting = requireExisting
            self.token = token
            self.queue = queue
            self.strings = strings
            self.clock = clock
            self.onClose = onClose
        }

        func start() {
            armHandshakeTimeout()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.close(detach: true)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }

        func stop() {
            close(detach: true)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    if self.isAttached {
                        self.forwardInput(data)
                    } else if self.isAttaching {
                        self.bufferInputUntilAttach(data)
                    } else {
                        self.consumeHandshake(data)
                    }
                }
                if isComplete {
                    // TCP half-close means the CLI is done sending stdin, but still
                    // expects PTY output until the remote session exits.
                    self.clientInputDidComplete = true
                    if self.isAttaching {
                        return
                    }
                    if !self.isAttached {
                        self.close(detach: false)
                    } else if self.clientHasExited() {
                        self.close(detach: true)
                    }
                    return
                }
                if error != nil {
                    self.close(detach: true)
                    return
                }
                self.receiveNext()
            }
        }

        private func consumeHandshake(_ data: Data) {
            handshakeBuffer.append(data)
            guard handshakeBuffer.count <= Self.maxHandshakeBytes else {
                close(detach: false)
                return
            }
            guard let newlineIndex = handshakeBuffer.firstIndex(of: 0x0A) else { return }
            var lineData = Data(handshakeBuffer[..<newlineIndex])
            let remainingStart = handshakeBuffer.index(after: newlineIndex)
            let remaining = remainingStart < handshakeBuffer.endIndex
                ? Data(handshakeBuffer[remainingStart...])
                : Data()
            handshakeBuffer.removeAll(keepingCapacity: false)
            if let carriageIndex = lineData.lastIndex(of: 0x0D),
               carriageIndex == lineData.index(before: lineData.endIndex) {
                lineData.remove(at: carriageIndex)
            }
            guard let payload = try? JSONSerialization.jsonObject(with: lineData, options: []) as? [String: Any],
                  let receivedToken = payload["token"] as? String,
                  receivedToken == token else {
                close(detach: false)
                return
            }
            let cols = Self.strictInt(payload["cols"]) ?? 80
            let rows = Self.strictInt(payload["rows"]) ?? 24
            clientPID = Self.strictPositivePID(payload["client_pid"])
            armClientProcessExitMonitor()
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            isAttaching = true
            if !remaining.isEmpty {
                bufferInputUntilAttach(remaining)
            }
            rpcQueue.async { [weak self] in
                guard let self else { return }
                let result: Result<RemotePTYBridgeAttachment, any Error>
                do {
                    let remoteAttachment = try self.rpcClient.attachBridgePTY(
                        sessionID: self.sessionID,
                        attachmentID: self.attachmentID,
                        cols: cols,
                        rows: rows,
                        command: self.command,
                        requireExisting: self.requireExisting,
                        queue: self.queue
                    ) { [weak self] event in
                        self?.handlePTYEvent(event)
                    }
                    result = .success(remoteAttachment)
                } catch {
                    result = .failure(error)
                }
                self.queue.async {
                    self.finishAttach(result)
                }
            }
        }

        private func finishAttach(_ result: Result<RemotePTYBridgeAttachment, any Error>) {
            guard !isClosed else {
                if case .success(let remoteAttachment) = result {
                    detachRemoteAttachment(remoteAttachment)
                }
                return
            }
            isAttaching = false
            do {
                let remoteAttachment = try result.get()
                self.remoteAttachment = remoteAttachment
                sendBridgeStatus([
                    "type": "ready",
                    "attachment_token": remoteAttachment.token,
                ])
                isAttached = true
                let pendingPTYEvents = pendingPTYEventsBeforeReady
                pendingPTYEventsBeforeReady.removeAll(keepingCapacity: false)
                pendingPTYEventBytesBeforeReady = 0
                for event in pendingPTYEvents {
                    handleAttachedPTYEvent(event)
                    if isClosed { return }
                }
                if !pendingInputBeforeAttach.isEmpty {
                    let pendingInput = pendingInputBeforeAttach
                    pendingInputBeforeAttach.removeAll(keepingCapacity: false)
                    forwardInput(pendingInput)
                }
                if clientInputDidComplete, clientHasExited() {
                    close(detach: true)
                }
            } catch {
                closeWithBridgeError(userFacingBridgeErrorMessage(error))
            }
        }

        private func armHandshakeTimeout() {
            // Bounded, cancellable timeout via the injected clock (legacy
            // used queue.asyncAfter); the isClosed/isAttached guards absorb
            // stale fires.
            handshakeTimeoutTask = Task { [weak self, clock] in
                guard (try? await clock.sleep(forMilliseconds: Self.handshakeTimeoutMilliseconds)) != nil else { return }
                guard let self else { return }
                self.queue.async {
                    guard !self.isClosed, !self.isAttached else { return }
                    self.close(detach: false)
                }
            }
        }

        private func bufferInputUntilAttach(_ data: Data) {
            guard !data.isEmpty else { return }
            guard pendingInputBeforeAttach.count <= Self.maxPendingInputBytes - data.count else {
                close(detach: false)
                return
            }
            pendingInputBeforeAttach.append(data)
        }

        private func forwardInput(_ data: Data) {
            guard !data.isEmpty else { return }
            guard let remoteAttachment else {
                close(detach: true)
                return
            }
            guard pendingInputWrites < Self.maxPendingInputWrites,
                  pendingInputBytes <= Self.maxPendingInputBytes - data.count else {
                close(detach: true)
                return
            }
            pendingInputWrites += 1
            pendingInputBytes += data.count
            let currentSessionID = sessionID
            rpcQueue.async { [weak self, data, remoteAttachment] in
                guard let self else { return }
                let shouldWrite = self.queue.sync { !self.isClosed }
                guard shouldWrite else {
                    self.queue.async {
                        self.handleInputWriteFinished(bytes: data.count, error: nil)
                    }
                    return
                }
                self.rpcClient.writePTY(
                    sessionID: currentSessionID,
                    attachmentID: remoteAttachment.attachmentID,
                    attachmentToken: remoteAttachment.token,
                    data: data
                ) { [weak self] writeError in
                    guard let self else { return }
                    self.queue.async {
                        self.handleInputWriteFinished(bytes: data.count, error: writeError)
                    }
                }
            }
        }

        private func handleInputWriteFinished(bytes: Int, error: (any Error)?) {
            pendingInputWrites = max(0, pendingInputWrites - 1)
            pendingInputBytes = max(0, pendingInputBytes - bytes)
            if error != nil {
                close(detach: true)
            }
        }

        private func detachRemoteAttachment(_ attachment: RemotePTYBridgeAttachment) {
            rpcQueue.async { [rpcClient, sessionID] in
                rpcClient.detachPTY(
                    sessionID: sessionID,
                    attachmentID: attachment.attachmentID,
                    attachmentToken: attachment.token
                )
            }
        }

        private func handlePTYEvent(_ event: RemotePTYBridgeEvent) {
            guard !isClosed else { return }
            guard !isAttaching else {
                bufferPTYEventUntilReady(event)
                return
            }
            handleAttachedPTYEvent(event)
        }

        private func bufferPTYEventUntilReady(_ event: RemotePTYBridgeEvent) {
            switch event {
            case .ready:
                return
            case .data(let data):
                guard !data.isEmpty else { return }
                guard pendingPTYEventsBeforeReady.count < Self.maxPendingOutputSends,
                      pendingPTYEventBytesBeforeReady <= Self.maxPendingOutputBytes - data.count else {
                    close(detach: true)
                    return
                }
                pendingPTYEventBytesBeforeReady += data.count
                pendingPTYEventsBeforeReady.append(event)
            case .exit, .error:
                guard pendingPTYEventsBeforeReady.count < Self.maxPendingOutputSends else {
                    close(detach: true)
                    return
                }
                pendingPTYEventsBeforeReady.append(event)
            }
        }

        private func handleAttachedPTYEvent(_ event: RemotePTYBridgeEvent) {
            guard !isClosed else { return }
            switch event {
            case .ready:
                return
            case .data(let data):
                guard !data.isEmpty else { return }
                sendBufferedOutput(data, detachOnOverflow: true)
            case .exit, .error:
                closeAfterOutputFlush(detach: false, gracefulOutputClose: true)
            }
        }

        private func sendBufferedOutput(_ data: Data, detachOnOverflow: Bool) {
            guard !isClosed, !data.isEmpty else { return }
            guard pendingOutputSends < Self.maxPendingOutputSends,
                  pendingOutputBytes <= Self.maxPendingOutputBytes - data.count else {
                close(detach: detachOnOverflow)
                return
            }

            pendingOutputSends += 1
            pendingOutputBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.handleOutputSendFinished(bytes: data.count, error: error)
                }
            })
        }

        private func handleOutputSendFinished(bytes: Int, error: NWError?) {
            guard !isClosed else { return }
            pendingOutputSends = max(0, pendingOutputSends - 1)
            pendingOutputBytes = max(0, pendingOutputBytes - bytes)
            if error != nil {
                close(detach: true)
                return
            }
            if let pendingClose = closeWhenOutputFlushes, pendingOutputSends == 0 {
                close(
                    detach: pendingClose.detach,
                    gracefulOutputClose: pendingClose.gracefulOutputClose
                )
            }
        }

        private func closeAfterOutputFlush(detach: Bool, gracefulOutputClose: Bool = false) {
            guard !isClosed else { return }
            if pendingOutputSends == 0 {
                close(detach: detach, gracefulOutputClose: gracefulOutputClose)
                return
            }
            closeWhenOutputFlushes = (detach: detach, gracefulOutputClose: gracefulOutputClose)
        }

        private func sendBridgeStatus(_ payload: [String: Any]) {
            guard !isClosed,
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                return
            }
            var line = data
            line.append(0x0A)
            sendBufferedOutput(line, detachOnOverflow: false)
        }

        private func closeWithBridgeError(_ message: String) {
            guard !isClosed else { return }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "remote PTY attach failed" : trimmed
            let payload: [String: Any] = ["type": "error", "message": detail]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                close(detach: false)
                return
            }
            var line = data
            line.append(0x0A)
            isClosed = true
            connection.send(content: line, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.connection.cancel()
                    self.onClose()
                }
            })
        }

        private func close(detach: Bool, gracefulOutputClose: Bool = false) {
            guard !isClosed else { return }
            isClosed = true
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            isAttaching = false
            pendingInputBeforeAttach.removeAll(keepingCapacity: false)
            pendingPTYEventsBeforeReady.removeAll(keepingCapacity: false)
            pendingPTYEventBytesBeforeReady = 0
            clientProcessExitSource?.cancel()
            clientProcessExitSource = nil
            if detach && isAttached, let remoteAttachment {
                detachRemoteAttachment(remoteAttachment)
            }
            if gracefulOutputClose && !detach {
                connection.send(
                    content: nil,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            self.connection.cancel()
                            self.onClose()
                        }
                    }
                )
                return
            }
            connection.cancel()
            onClose()
        }

        private static func strictInt(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let number = value as? NSNumber {
                let double = number.doubleValue
                guard double.rounded(.towardZero) == double else { return nil }
                return number.intValue
            }
            return nil
        }

        private static func strictPositivePID(_ value: Any?) -> pid_t? {
            guard let intValue = strictInt(value),
                  intValue > 0,
                  intValue <= Int(Int32.max) else {
                return nil
            }
            return pid_t(intValue)
        }

        private func armClientProcessExitMonitor() {
            // DispatchSource justification: owned by this queue-confined
            // session, never exposed, cancelled in close(); the
            // actor+AsyncStream migration is a flagged later-phase item.
            clientProcessExitSource?.cancel()
            clientProcessExitSource = nil
            guard let clientPID, Self.processIsRunning(clientPID) else { return }
            let source = DispatchSource.makeProcessSource(identifier: clientPID, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                self?.close(detach: true)
            }
            clientProcessExitSource = source
            source.resume()
        }

        private func clientHasExited() -> Bool {
            guard let clientPID else { return false }
            return !Self.processIsRunning(clientPID)
        }

        private static func processIsRunning(_ pid: pid_t) -> Bool {
            guard pid > 0 else { return false }
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }

        /// Maps a daemon attach failure onto the app-resolved user-facing
        /// string; the matching rules (substring markers, in this order) are
        /// wire-pinned legacy behavior.
        func userFacingBridgeErrorMessage(_ error: any Error) -> String {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = message.lowercased()
            if lowered.contains("missing required capability") ||
                lowered.contains("pty.session") ||
                lowered.contains(RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) {
                return strings.missingPersistentPTYCapability
            }
            if lowered.contains("pty_session_not_found") ||
                (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
                (lowered.contains("persistent pty session") && lowered.contains("not running")) {
                return strings.sessionEnded
            }
            if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
                return strings.inputBackedUp
            }
            if lowered.contains("timed out") || lowered.contains("timeout") {
                return strings.daemonTimeout
            }
            // Surface the daemon's PTY-allocation diagnostic (it names the failing
            // device and the devpts/ptmxmode cause) instead of collapsing it into a
            // generic message. Key off the daemon's stable marker only, so an
            // unrelated error that merely mentions a device path is not leaked.
            // See https://github.com/manaflow-ai/cmux/issues/5185.
            if lowered.contains("could not allocate a remote pty") {
                return strings.allocationDiagnostic(message)
            }
            return strings.attachFailed
        }
    }
}
