import CMUXVNC
import Darwin
import Foundation

final class VNCPanelConnection {
    typealias ControlHandler = @MainActor (VNCControlMessage) -> Void
    typealias FrameHandler = @MainActor (VNCFrameHeader, Data) -> Void
    typealias ExitHandler = @MainActor (String, Bool) -> Void

    private let session: MacfleetVNCSession
    private let credential: VNCResolvedCredential
    private let onControl: ControlHandler
    private let onFrame: FrameHandler
    private let onExit: ExitHandler
    private let socketPath: String
    private let ioQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let stateLock = NSLock()

    private var process: Process?
    private var listenerFileDescriptor: Int32 = -1
    private var clientFileDescriptor: Int32 = -1
    private var isClosed = false

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
        self.socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vnc-\(UUID().uuidString).sock")
            .path
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
            let listener = try Self.createListeningSocket(path: socketPath)
            let shouldCloseListener = stateLock.withLock { () -> Bool in
                if isClosed { return true }
                listenerFileDescriptor = listener
                return false
            }
            if shouldCloseListener {
                Darwin.close(listener)
                unlink(socketPath)
                return
            }
            try launchHelper()
            let request = VNCConnectRequest(
                sessionName: session.name,
                host: session.address,
                port: session.port,
                username: credential.username,
                password: credential.password
            )
            acceptAndRead(connectRequest: request)
        } catch {
            close()
            notifyMainExit(VNCPanelText.helperLaunchFailed(error.localizedDescription), shouldRestart: false)
        }
    }

    func sendControl(_ control: VNCControlMessage) {
        guard !isCurrentlyClosed() else { return }
        do {
            let message = try VNCIPCCodec.encodeControl(control)
            writeQueue.async { [weak self] in
                guard let fileDescriptor = self?.clientFileDescriptorForWrite() else { return }
                Self.write(message, to: fileDescriptor)
            }
        } catch {
            notifyMainExit(VNCPanelText.helperProtocolFailed(error.localizedDescription), shouldRestart: false)
        }
    }

    func close() {
        let state = stateLock.withLock { () -> (client: Int32, listener: Int32, process: Process?)? in
            guard !isClosed else { return nil }
            isClosed = true
            let state = (
                client: clientFileDescriptor,
                listener: listenerFileDescriptor,
                process: process
            )
            clientFileDescriptor = -1
            listenerFileDescriptor = -1
            self.process = nil
            return state
        }
        guard let state else { return }
        if state.client >= 0 {
            _ = Darwin.shutdown(state.client, SHUT_RDWR)
            Darwin.close(state.client)
        }
        if state.listener >= 0 {
            Darwin.close(state.listener)
        }
        unlink(socketPath)
        state.process?.terminate()
    }

    private func launchHelper() throws {
        let helperURL = try Self.resolveHelperURL()
        let process = Process()
        process.executableURL = helperURL
        var arguments = ["--socket", socketPath]
        if Self.shouldUseFakeHelper {
            arguments.append("--fake")
        }
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, !self.isCurrentlyClosed() else { return }
                let status = process.terminationStatus
                self.close()
                self.onExit(VNCPanelText.helperExited(Int(status)), status != 0)
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

    private func acceptAndRead(connectRequest: VNCConnectRequest) {
        let listener = stateLock.withLock { listenerFileDescriptor }
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else {
            if isCurrentlyClosed() { return }
            notifyExit(VNCPanelText.socketAcceptFailed(errno), shouldRestart: true)
            return
        }

        let listenerToClose = stateLock.withLock { () -> Int32? in
            if isClosed {
                return nil
            }
            clientFileDescriptor = accepted
            let currentListener = listenerFileDescriptor
            listenerFileDescriptor = -1
            return currentListener
        }
        guard let listenerToClose else {
            Darwin.close(accepted)
            return
        }
        if listenerToClose >= 0 {
            Darwin.close(listenerToClose)
        }

        do {
            let connectMessage = try VNCIPCCodec.encodeControl(.connect(connectRequest))
            Self.write(connectMessage, to: accepted)
            readMessages(from: accepted)
        } catch {
            notifyExit(VNCPanelText.helperProtocolFailed(error.localizedDescription), shouldRestart: true)
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
                    notifyExit(VNCPanelText.helperProtocolFailed(error.localizedDescription), shouldRestart: true)
                    return
                }
                continue
            }
            if byteCount == 0 {
                notifyExit(VNCPanelText.helperDisconnected, shouldRestart: false)
                return
            }
            if errno == EINTR {
                continue
            }
            notifyExit(VNCPanelText.socketReadFailed(errno), shouldRestart: true)
            return
        }
    }

    private func publish(_ message: VNCIPCMessage) {
        Task { @MainActor in
            guard !isCurrentlyClosed() else { return }
            switch message {
            case .control(let control):
                onControl(control)
            case .frame(let header, let payload):
                onFrame(header, payload)
            }
        }
    }

    private func notifyExit(_ reason: String, shouldRestart: Bool) {
        Task { @MainActor in
            guard !isCurrentlyClosed() else { return }
            close()
            onExit(reason, shouldRestart)
        }
    }

    private func notifyMainExit(_ reason: String, shouldRestart: Bool) {
        Task { @MainActor in
            close()
            onExit(reason, shouldRestart)
        }
    }

    private func isCurrentlyClosed() -> Bool {
        stateLock.withLock { isClosed }
    }

    private func clientFileDescriptorForWrite() -> Int32? {
        stateLock.withLock {
            guard !isClosed, clientFileDescriptor >= 0 else { return nil }
            return clientFileDescriptor
        }
    }

    private static func write(_ data: Data, to fileDescriptor: Int32) {
        data.withUnsafeBytes { bytes in
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
                return
            }
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

    private static func createListeningSocket(path: String) throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw VNCPanelConnectionError.socketCreationFailed(errno)
        }

        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            Darwin.close(fileDescriptor)
            throw VNCPanelConnectionError.socketPathTooLong
        }
        path.withCString { pathPointer in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                let source = UnsafeRawBufferPointer(start: pathPointer, count: path.utf8.count + 1)
                destination.copyBytes(from: source)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    fileDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
                )
            }
        }
        guard bindResult == 0 else {
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            unlink(path)
            throw VNCPanelConnectionError.socketBindFailed(capturedErrno)
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            unlink(path)
            throw VNCPanelConnectionError.socketPermissionFailed(capturedErrno)
        }
        guard listen(fileDescriptor, 1) == 0 else {
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            unlink(path)
            throw VNCPanelConnectionError.socketListenFailed(capturedErrno)
        }
        return fileDescriptor
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
    case socketPathTooLong
    case socketBindFailed(Int32)
    case socketPermissionFailed(Int32)
    case socketListenFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return VNCPanelText.helperMissing
        case .socketCreationFailed(let error):
            return VNCPanelText.socketCreationFailed(error)
        case .socketPathTooLong:
            return VNCPanelText.socketPathTooLong
        case .socketBindFailed(let error):
            return VNCPanelText.socketBindFailed(error)
        case .socketPermissionFailed(let error):
            return VNCPanelText.socketPermissionFailed(error)
        case .socketListenFailed(let error):
            return VNCPanelText.socketListenFailed(error)
        }
    }
}
