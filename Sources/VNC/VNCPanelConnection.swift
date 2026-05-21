import CMUXVNC
import Darwin
import Foundation

enum VNCPanelConnectionExit {
    case disconnected
    case failure(reason: String, shouldRestart: Bool)
}

final class VNCPanelConnection {
    private static let helperConnectionFailureExitStatus: Int32 = 67

    typealias ControlHandler = @MainActor (VNCControlMessage) -> Void
    typealias FrameHandler = @MainActor (VNCFrameHeader, Data) -> Void
    typealias ExitHandler = @MainActor (VNCPanelConnectionExit) -> Void

    private let session: MacfleetVNCSession
    private let credential: VNCResolvedCredential
    private let onControl: ControlHandler
    private let onFrame: FrameHandler
    private let onExit: ExitHandler
    private let ioQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let stateLock = NSLock()

    private var process: Process?
    private var clientFileDescriptor: Int32 = -1
    private var pendingControlMessages: [Data] = []
    private var framebufferComposer = VNCFramebufferComposer()
    private var helperReportedFailureReason: String?
    private var isClosed = false

    private enum AcceptedClientActivationResult {
        case active
        case closed
        case failedBeforePublish
        case failedAfterPublish
    }

    init(
        session: MacfleetVNCSession,
        credential: VNCResolvedCredential,
        onControl: @escaping ControlHandler,
        onFrame: @escaping FrameHandler,
        onExit: @escaping ExitHandler
    ) {
        self.session = session
        self.credential = credential
        self.onControl = onControl
        self.onFrame = onFrame
        self.onExit = onExit
        self.ioQueue = DispatchQueue(label: "dev.cmux.vnc.\(session.name)")
        self.writeQueue = DispatchQueue(label: "dev.cmux.vnc.\(session.name).write")
    }

    func start() {
        ioQueue.async { [weak self] in
            self?.startOnIOQueue()
        }
    }

    private func startOnIOQueue() {
        do {
            let socketPair = try Self.createSocketPair()
            var parentSocket: Int32? = socketPair.parent
            var childSocket: Int32? = socketPair.child
            defer {
                if let childSocket {
                    Darwin.close(childSocket)
                }
                if let parentSocket {
                    Darwin.close(parentSocket)
                }
            }

            if isCurrentlyClosed() {
                return
            }
            try launchHelper(inheritedSocket: socketPair.child)
            Darwin.close(socketPair.child)
            childSocket = nil
            let request = VNCConnectRequest(
                sessionName: session.name,
                host: session.address,
                port: session.port,
                username: credential.username,
                password: credential.password
            )
            let activationResult = activateAcceptedClient(socketPair.parent, connectRequest: request)
            switch activationResult {
            case .active:
                parentSocket = nil
                readMessages(from: socketPair.parent)
            case .closed:
                return
            case .failedBeforePublish:
                notifyExit(.failure(reason: VNCPanelText.helperProtocolFailed, shouldRestart: true))
            case .failedAfterPublish:
                parentSocket = nil
                notifyExit(.failure(reason: VNCPanelText.helperProtocolFailed, shouldRestart: true))
            }
        } catch {
            close()
            notifyMainExit(.failure(reason: VNCPanelText.helperLaunchFailed, shouldRestart: false))
        }
    }

    func sendControl(_ control: VNCControlMessage) {
        guard !isCurrentlyClosed() else { return }
        do {
            let message = try VNCIPCCodec.encodeControl(control)
            writeQueue.async { [weak self] in
                do {
                    guard let fileDescriptor = try self?.clientFileDescriptorForWrite(orQueue: message) else { return }
                    defer { Darwin.close(fileDescriptor) }
                    try Self.write(message, to: fileDescriptor)
                } catch {
                    self?.notifyExit(.failure(reason: VNCPanelText.helperDisconnected, shouldRestart: false))
                }
            }
        } catch {
            notifyMainExit(.failure(reason: VNCPanelText.helperProtocolFailed, shouldRestart: false))
        }
    }

    func close() {
        let state = stateLock.withLock { () -> (client: Int32, process: Process?)? in
            guard !isClosed else { return nil }
            isClosed = true
            let state = (
                client: clientFileDescriptor,
                process: process
            )
            clientFileDescriptor = -1
            pendingControlMessages.removeAll(keepingCapacity: false)
            self.process = nil
            return state
        }
        guard let state else { return }
        DispatchQueue.global(qos: .utility).async {
            if state.client >= 0 {
                _ = Darwin.shutdown(state.client, SHUT_RDWR)
                Darwin.close(state.client)
            }
            state.process?.terminate()
        }
    }

    private func launchHelper(inheritedSocket: Int32) throws {
        let helperURL = try Self.resolveHelperURL()
        let process = Process()
        process.executableURL = helperURL
        var arguments = ["--fd", "0"]
        if Self.shouldUseFakeHelper {
            arguments.append("--fake")
        }
        process.arguments = arguments
        process.standardInput = FileHandle(fileDescriptor: inheritedSocket, closeOnDealloc: false)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, !self.isCurrentlyClosed() else { return }
                let status = process.terminationStatus
                let exit = self.helperExit(for: status)
                self.close()
                self.onExit(exit)
            }
        }
        try process.run()
        let shouldTerminate = stateLock.withLock { () -> Bool in
            if isClosed { return true }
            self.process = process
            return false
        }
        if shouldTerminate {
            process.terminate()
        }
    }

    private func activateAcceptedClient(_ accepted: Int32, connectRequest: VNCConnectRequest) -> AcceptedClientActivationResult {
        let connectMessage: Data
        do {
            connectMessage = try VNCIPCCodec.encodeControl(.connect(connectRequest))
        } catch {
            return .failedBeforePublish
        }

        return writeQueue.sync {
            var published = false
            do {
                guard let initialPending = stateLock.withLock({ () -> [Data]? in
                    guard !isClosed else { return nil }
                    let pending = pendingControlMessages
                    pendingControlMessages.removeAll(keepingCapacity: false)
                    return pending
                }) else {
                    return .closed
                }

                try Self.write(connectMessage, to: accepted)
                for message in initialPending {
                    try Self.write(message, to: accepted)
                }

                guard let pendingAfterPublish = stateLock.withLock({ () -> [Data]? in
                    guard !isClosed else { return nil }
                    clientFileDescriptor = accepted
                    published = true
                    let pending = pendingControlMessages
                    pendingControlMessages.removeAll(keepingCapacity: false)
                    return pending
                }) else {
                    return .closed
                }
                for message in pendingAfterPublish {
                    try Self.write(message, to: accepted)
                }
                return .active
            } catch {
                return published ? .failedAfterPublish : .failedBeforePublish
            }
        }
    }

    private func readMessages(from fileDescriptor: Int32) {
        var decoder = VNCIPCStreamDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let byteCount = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if byteCount > 0 {
                do {
                    let payload = Data(buffer.prefix(Int(byteCount)))
                    let messages = try decoder.append(payload)
                    for message in messages {
                        publish(message)
                    }
                } catch {
                    notifyExit(.failure(reason: VNCPanelText.helperProtocolFailed, shouldRestart: true))
                    return
                }
                continue
            }
            if byteCount == 0 {
                clearClientFileDescriptor(fileDescriptor)
                return
            }
            if errno == EINTR {
                continue
            }
            notifyExit(.failure(reason: VNCPanelText.socketReadFailed(errno), shouldRestart: true))
            return
        }
    }

    private func publish(_ message: VNCIPCMessage) {
        switch message {
        case .control(let control):
            let failedReason = control.state == "failed" ? (control.message ?? VNCPanelText.stateFailed) : nil
            if let failedReason {
                recordHelperReportedFailure(reason: failedReason)
            }
            Task { @MainActor in
                guard !isCurrentlyClosed() else { return }
                onControl(control)
                if control.state == "failed" {
                    let reason = failedReason ?? VNCPanelText.stateFailed
                    close()
                    onExit(.failure(reason: reason, shouldRestart: false))
                }
            }
        case .frame(let header, let payload):
            guard let frame = framebufferComposer.apply(header: header, payload: payload) else { return }
            Task { @MainActor in
                guard !isCurrentlyClosed() else { return }
                onFrame(frame.header, frame.payload)
            }
        }
    }

    private func recordHelperReportedFailure(reason: String) {
        stateLock.withLock {
            helperReportedFailureReason = reason
        }
    }

    private func helperExit(for status: Int32) -> VNCPanelConnectionExit {
        if status == 0 {
            return .disconnected
        }
        if status == Self.helperConnectionFailureExitStatus {
            let reason = stateLock.withLock { helperReportedFailureReason } ?? VNCPanelText.stateFailed
            return .failure(reason: reason, shouldRestart: false)
        }
        return .failure(reason: VNCPanelText.helperExited(Int(status)), shouldRestart: true)
    }

    private func notifyExit(_ exit: VNCPanelConnectionExit) {
        Task { @MainActor in
            guard !isCurrentlyClosed() else { return }
            close()
            onExit(exit)
        }
    }

    private func notifyMainExit(_ exit: VNCPanelConnectionExit) {
        Task { @MainActor in
            close()
            onExit(exit)
        }
    }

    private func isCurrentlyClosed() -> Bool {
        stateLock.withLock { isClosed }
    }

    private func clientFileDescriptorForWrite(orQueue message: Data) throws -> Int32? {
        try stateLock.withLock {
            guard !isClosed else { return nil }
            if clientFileDescriptor >= 0 {
                let duplicateFileDescriptor = Darwin.dup(clientFileDescriptor)
                guard duplicateFileDescriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                Self.disableSIGPIPE(on: duplicateFileDescriptor)
                return duplicateFileDescriptor
            }
            pendingControlMessages.append(message)
            return nil
        }
    }

    private func clearClientFileDescriptor(_ fileDescriptor: Int32) {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard clientFileDescriptor == fileDescriptor else { return false }
            clientFileDescriptor = -1
            return true
        }
        if shouldClose {
            Darwin.close(fileDescriptor)
        }
    }

    private static func write(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, baseAddress, remaining)
                if written > 0 {
                    remaining -= written
                    baseAddress += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func disableSIGPIPE(on fileDescriptor: Int32) {
        var value: Int32 = 1
        withUnsafePointer(to: &value) { pointer in
            _ = setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }

    private static func resolveHelperURL() throws -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["CMUX_VNC_HELPER_PATH"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath)
        }
        guard let resourceURL = Bundle.main.resourceURL else {
            throw VNCPanelConnectionError.helperMissing
        }
        let helperURL = resourceURL.appendingPathComponent("bin/cmux-vnc-helper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw VNCPanelConnectionError.helperMissing
        }
        return helperURL
    }

    private static var shouldUseFakeHelper: Bool {
        let value = ProcessInfo.processInfo.environment["CMUX_VNC_HELPER_FAKE"] ?? ""
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
    }

    private static func createSocketPair() throws -> (parent: Int32, child: Int32) {
        var fileDescriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fileDescriptors) == 0 else {
            throw VNCPanelConnectionError.socketCreationFailed(errno)
        }
        disableSIGPIPE(on: fileDescriptors[0])
        disableSIGPIPE(on: fileDescriptors[1])
        return (parent: fileDescriptors[0], child: fileDescriptors[1])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum VNCPanelConnectionError: LocalizedError {
    case helperMissing
    case socketCreationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return VNCPanelText.helperMissing
        case .socketCreationFailed(let error):
            return VNCPanelText.socketCreationFailed(error)
        }
    }
}
