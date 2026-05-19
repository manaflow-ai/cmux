import CMUXVNC
import CoreGraphics
import Darwin
import Foundation
import RoyalVNCKit

private enum HelperExit: Int32 {
    case usage = 64
    case socket = 65
    case protocolError = 66
}

private final class SocketChannel: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    func send(_ data: Data) throws {
        try writeLock.withLock {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var sent = 0
                while sent < rawBuffer.count {
                    let result = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if result == 0 {
                        throw POSIXError(.EPIPE)
                    }
                    sent += result
                }
            }
        }
    }

    func readMessage() throws -> VNCIPCMessage? {
        guard let lengthData = try readExactly(byteCount: 4) else { return nil }
        let length = Int(lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length <= VNCIPCCodec.maxMessageLength else {
            throw VNCIPCError.payloadTooLarge
        }
        guard let payload = try readExactly(byteCount: length) else { return nil }
        return try VNCIPCCodec.decodePayload(payload)
    }

    private func readExactly(byteCount: Int) throws -> Data? {
        var output = Data(count: byteCount)
        let completed = try output.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var readCount = 0
            while readCount < byteCount {
                let result = Darwin.read(fd, base.advanced(by: readCount), byteCount - readCount)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if result == 0 {
                    return false
                }
                readCount += result
            }
            return true
        }
        return completed ? output : nil
    }
}

private final class VNCSessionController: NSObject, VNCConnectionDelegate, @unchecked Sendable {
    private let channel: SocketChannel
    private let request: VNCConnectRequest
    private let termination = DispatchSemaphore(value: 0)
    private let connectionLock = NSLock()
    private let stateLock = NSLock()
    private var connection: VNCConnection?
    private var sequence: UInt64 = 0
    private var isClosed = false

    init(channel: SocketChannel, request: VNCConnectRequest) {
        self.channel = channel
        self.request = request
    }

    func start() {
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: request.host,
            port: UInt16(request.port),
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .none,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        connectionLock.withLock { self.connection = connection }
        connection.connect()
    }

    func waitUntilTerminated() {
        termination.wait()
    }

    func handle(_ message: VNCControlMessage) {
        switch message.kind {
        case "close":
            close()
        case "text":
            guard let text = message.text else { return }
            let keys = VNCKeyCode.keyCodesFrom(characters: text)
            withConnection { connection in
                for key in keys {
                    connection.keyDown(key)
                    connection.keyUp(key)
                }
            }
        case "key":
            guard let keyCodeValue = message.keyCode,
                  let isDown = message.isDown,
                  let keyCode = UInt16(exactly: keyCodeValue),
                  let remoteKey = VNCKeyCode.from(cgKeyCode: CGKeyCode(keyCode)) else {
                return
            }
            withConnection { connection in
                if isDown {
                    connection.keyDown(remoteKey)
                } else {
                    connection.keyUp(remoteKey)
                }
            }
        case "pointer":
            guard let x = message.x, let y = message.y else { return }
            let clampedX = UInt16(max(0, min(UInt16.max.intValue, x)))
            let clampedY = UInt16(max(0, min(UInt16.max.intValue, y)))
            withConnection { connection in
                if let button = message.button, let mouseButton = VNCMouseButton(rawValue: button), let isDown = message.isDown {
                    if isDown {
                        connection.mouseButtonDown(mouseButton, x: clampedX, y: clampedY)
                    } else {
                        connection.mouseButtonUp(mouseButton, x: clampedX, y: clampedY)
                    }
                } else {
                    connection.mouseMove(x: clampedX, y: clampedY)
                }
            }
        case "visibility":
            break
        default:
            break
        }
    }

    func close() {
        guard markClosed() else { return }
        withConnection { $0.disconnect() }
        termination.signal()
    }

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let state: String
        switch connectionState.status {
        case .connecting:
            state = "connecting"
        case .connected:
            state = "connected"
        case .disconnecting:
            state = "disconnecting"
        case .disconnected:
            state = "disconnected"
        }
        sendControl(VNCControlMessage(kind: "state", sessionName: request.sessionName, state: state))
        if connectionState.status == .disconnected {
            termination.signal()
        }
    }

    func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: request.username, password: request.password))
        } else if authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: request.password))
        } else {
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        sendControl(VNCControlMessage(
            kind: "size",
            sessionName: request.sessionName,
            width: Int(framebuffer.size.width),
            height: Int(framebuffer.size.height)
        ))
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        sendControl(VNCControlMessage(
            kind: "size",
            sessionName: request.sessionName,
            width: Int(framebuffer.size.width),
            height: Int(framebuffer.size.height)
        ))
    }

    func connection(
        _ connection: VNCConnection,
        didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) {
        let framebufferWidth = Int(framebuffer.size.width)
        let framebufferHeight = Int(framebuffer.size.height)
        let rectWidth = Int(width)
        let rectHeight = Int(height)
        let rectX = Int(x)
        let rectY = Int(y)
        let (rowBytes, rowBytesOverflow) = framebufferWidth.multipliedReportingOverflow(by: 4)
        let (rectRowBytes, rectRowBytesOverflow) = rectWidth.multipliedReportingOverflow(by: 4)
        let (byteCount, byteCountOverflow) = rectRowBytes.multipliedReportingOverflow(by: rectHeight)
        guard !rowBytesOverflow, !rectRowBytesOverflow, !byteCountOverflow else {
            close()
            return
        }
        guard byteCount > 0 else { return }

        let nextSequence = stateLock.withLock { () -> UInt64 in
            sequence &+= 1
            return sequence
        }
        let header = VNCFrameHeader(
            sequence: nextSequence,
            x: rectX,
            y: rectY,
            width: rectWidth,
            height: rectHeight,
            framebufferWidth: framebufferWidth,
            framebufferHeight: framebufferHeight,
            stride: rectRowBytes,
            pixelFormat: .bgra8
        )
        guard VNCFrameValidator.validate(header: header, payloadByteCount: byteCount) == nil else {
            close()
            return
        }

        let sourceBase = framebuffer.surfaceAddress
        var payload = Data(count: byteCount)
        payload.withUnsafeMutableBytes { outputBuffer in
            guard let destination = outputBuffer.baseAddress else { return }
            for row in 0..<rectHeight {
                let sourceOffset = ((rectY + row) * rowBytes) + (rectX * 4)
                let destinationOffset = row * rectRowBytes
                memcpy(destination.advanced(by: destinationOffset), sourceBase.advanced(by: sourceOffset), rectRowBytes)
            }
        }

        do {
            try channel.send(try VNCIPCCodec.encodeFrame(header: header, payload: payload))
        } catch {
            close()
        }
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        _ = cursor
    }

    private func sendControl(_ message: VNCControlMessage) {
        do {
            try channel.send(try VNCIPCCodec.encodeControl(message))
        } catch {
            close()
        }
    }

    private func withConnection(_ body: (VNCConnection) -> Void) {
        connectionLock.withLock {
            guard let connection else { return }
            body(connection)
        }
    }

    private func markClosed() -> Bool {
        stateLock.withLock {
            if isClosed { return false }
            isClosed = true
            return true
        }
    }
}

private func connectUnixSocket(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxPathLength else {
        Darwin.close(fd)
        throw POSIXError(.ENAMETOOLONG)
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        path.withCString { source in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, maxPathLength)
        }
    }

    let result = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    return fd
}

private func runFake(channel: SocketChannel) {
    do {
        try channel.send(try VNCIPCCodec.encodeControl(VNCControlMessage(kind: "state", state: "connected")))
        let width = 96
        let height = 64
        var payload = Data(count: width * height * 4)
        payload.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    bytes[offset] = UInt8((x * 2) % 255)
                    bytes[offset + 1] = UInt8((y * 3) % 255)
                    bytes[offset + 2] = 0x30
                    bytes[offset + 3] = 0xff
                }
            }
        }
        let header = VNCFrameHeader(
            sequence: 1,
            x: 0,
            y: 0,
            width: width,
            height: height,
            framebufferWidth: width,
            framebufferHeight: height,
            stride: width * 4
        )
        try channel.send(try VNCIPCCodec.encodeFrame(header: header, payload: payload))
        while let message = try channel.readMessage() {
            if case .control(let control) = message, control.kind == "close" {
                break
            }
        }
    } catch {
        return
    }
}

private func parseSocketPath(arguments: [String]) -> (socketPath: String?, fake: Bool) {
    var socketPath: String?
    var fake = false
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--socket":
            if index + 1 < arguments.count {
                socketPath = arguments[index + 1]
                index += 1
            }
        case "--fake":
            fake = true
        default:
            break
        }
        index += 1
    }
    return (socketPath, fake)
}

let parsed = parseSocketPath(arguments: CommandLine.arguments)
guard let socketPath = parsed.socketPath else {
    fputs("usage: cmux-vnc-helper --socket <path> [--fake]\n", stderr)
    exit(HelperExit.usage.rawValue)
}

do {
    let fd = try connectUnixSocket(path: socketPath)
    let channel = SocketChannel(fd: fd)
    if parsed.fake || ProcessInfo.processInfo.environment["CMUX_VNC_HELPER_FAKE"] == "1" {
        runFake(channel: channel)
        exit(0)
    }
    guard case .control(let control)? = try channel.readMessage(),
          control.kind == "connect",
          let sessionName = control.sessionName,
          let host = control.host,
          let port = control.port,
          let username = control.username,
          let password = control.password,
          (1...65_535).contains(port) else {
        exit(HelperExit.protocolError.rawValue)
    }
    let request = VNCConnectRequest(
        sessionName: sessionName,
        host: host,
        port: port,
        username: username,
        password: password
    )
    let controller = VNCSessionController(channel: channel, request: request)
    controller.start()
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            while let message = try channel.readMessage() {
                if case .control(let control) = message {
                    controller.handle(control)
                    if control.kind == "close" { break }
                }
            }
            controller.close()
        } catch {
            controller.close()
        }
    }
    controller.waitUntilTerminated()
    exit(0)
} catch {
    fputs("cmux-vnc-helper socket error\n", stderr)
    exit(HelperExit.socket.rawValue)
}

private extension UInt16 {
    var intValue: Int { Int(self) }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
