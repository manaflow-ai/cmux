import CMUXVNC
import Darwin
import Foundation

@MainActor
final class VNCPanelConnection {
    typealias ControlHandler = @MainActor (VNCControlMessage) -> Void
    typealias FrameHandler = @MainActor (VNCFrameHeader, Data) -> Void
    typealias ExitHandler = @MainActor (String) -> Void

    private let session: MacfleetVNCSession
    private let credential: VNCResolvedCredential
    private let onControl: ControlHandler
    private let onFrame: FrameHandler
    private let onExit: ExitHandler
    private let socketPath: String
    private let ioQueue: DispatchQueue

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
    }

    func start() {
        do {
            listenerFileDescriptor = try Self.createListeningSocket(path: socketPath)
            try launchHelper()
            let request = VNCConnectRequest(
                sessionName: session.name,
                host: session.address,
                port: session.port,
                username: credential.username,
                password: credential.password
            )
            ioQueue.async { [weak self] in
                self?.acceptAndRead(connectRequest: request)
            }
        } catch {
            close()
            onExit(VNCPanelText.helperLaunchFailed(error.localizedDescription))
        }
    }

    func sendControl(_ control: VNCControlMessage) {
        guard !isClosed else { return }
        do {
            let message = try VNCIPCCodec.encodeControl(control)
            ioQueue.async { [weak self] in
                self?.write(message)
            }
        } catch {
            onExit(VNCPanelText.helperProtocolFailed(error.localizedDescription))
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if clientFileDescriptor >= 0 {
            let closeMessage = try? VNCIPCCodec.encodeControl(VNCControlMessage(kind: "close"))
            if let closeMessage {
                write(closeMessage)
            }
            Darwin.close(clientFileDescriptor)
            clientFileDescriptor = -1
        }
        if listenerFileDescriptor >= 0 {
            Darwin.close(listenerFileDescriptor)
            listenerFileDescriptor = -1
        }
        unlink(socketPath)
        process?.terminate()
        process = nil
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
        let standardError = Pipe()
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                let status = process.terminationStatus
                self.close()
                self.onExit(VNCPanelText.helperExited(Int(status)))
            }
        }
        try process.run()
        self.process = process
    }

    private func acceptAndRead(connectRequest: VNCConnectRequest) {
        let accepted = Darwin.accept(listenerFileDescriptor, nil, nil)
        guard accepted >= 0 else {
            notifyExit(VNCPanelText.socketAcceptFailed(errno))
            return
        }

        Task { @MainActor in
            self.clientFileDescriptor = accepted
            if self.listenerFileDescriptor >= 0 {
                Darwin.close(self.listenerFileDescriptor)
                self.listenerFileDescriptor = -1
            }
        }

        do {
            let connectMessage = try VNCIPCCodec.encodeControl(.connect(connectRequest))
            write(connectMessage, to: accepted)
            readMessages(from: accepted)
        } catch {
            notifyExit(VNCPanelText.helperProtocolFailed(error.localizedDescription))
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
                    notifyExit(VNCPanelText.helperProtocolFailed(error.localizedDescription))
                    return
                }
                continue
            }
            if byteCount == 0 {
                notifyExit(VNCPanelText.helperDisconnected)
                return
            }
            if errno == EINTR {
                continue
            }
            notifyExit(VNCPanelText.socketReadFailed(errno))
            return
        }
    }

    private func publish(_ message: VNCIPCMessage) {
        Task { @MainActor in
            guard !isClosed else { return }
            switch message {
            case .control(let control):
                onControl(control)
            case .frame(let header, let payload):
                onFrame(header, payload)
            }
        }
    }

    private func notifyExit(_ reason: String) {
        Task { @MainActor in
            guard !isClosed else { return }
            close()
            onExit(reason)
        }
    }

    private func write(_ data: Data) {
        guard clientFileDescriptor >= 0 else { return }
        write(data, to: clientFileDescriptor)
    }

    private func write(_ data: Data, to fileDescriptor: Int32) {
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
