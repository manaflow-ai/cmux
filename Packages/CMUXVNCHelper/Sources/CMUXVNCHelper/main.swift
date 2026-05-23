import CMUXVNC
import CoreGraphics
import Darwin
import Foundation
@preconcurrency import RoyalVNCKit

private enum HelperExit: Int32 {
    case usage = 64
    case socket = 65
    case protocolError = 66
    case connection = 67
    case inputQueueFull = 68
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
    private static let maxPendingInputMessages = 512

    private let channel: SocketChannel
    private let request: VNCConnectRequest
    private let connectionQueue = DispatchQueue(label: "com.cmux.vnc-helper.connection")
    private let connectionQueueKey = DispatchSpecificKey<Void>()
    private let connectionLock = NSLock()
    private let frameSnapshotLock = NSLock()
    private let stateLock = NSLock()
    private let inputLock = NSLock()
    private let exitCodeLock = NSLock()
    private let terminationLock = NSLock()
    private var connection: VNCConnection?
    private var frameGate = VNCVisibilityFrameGate()
    private var isClosed = false
    private var isRemoteInputReady = false
    private var pendingInputMessages = VNCControlMessageQueue(maxMessages: maxPendingInputMessages)
    private var requestedExitCode: Int32 = 0
    private var isTerminated = false
    private var terminationHandler: (() -> Void)?

    private enum PendingInputDecision {
        case process
        case queued
        case failed
    }

    private struct FrameSnapshot: Sendable {
        var header: VNCFrameHeader
        var payload: Data
    }

    init(channel: SocketChannel, request: VNCConnectRequest) {
        self.channel = channel
        self.request = request
        connectionQueue.setSpecific(key: connectionQueueKey, value: ())
    }

    func start() {
        runOnConnectionQueue { [weak self] in
            self?.startOnConnectionQueue()
        }
    }

    private func startOnConnectionQueue() {
        guard !isCurrentlyClosed() else { return }
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: request.host,
            port: UInt16(request.port),
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        connectionLock.withLock { self.connection = connection }
        connection.connect()
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        let shouldCallNow = terminationLock.withLock { () -> Bool in
            terminationHandler = handler
            return isTerminated
        }
        if shouldCallNow {
            handler()
        }
    }

    var hasTerminated: Bool {
        terminationLock.withLock { isTerminated }
    }

    var exitCode: Int32 {
        exitCodeLock.withLock { requestedExitCode }
    }

    func handle(_ message: VNCControlMessage) {
        runOnConnectionQueue { [weak self] in
            self?.handleOnConnectionQueue(message)
        }
    }

    private func handleOnConnectionQueue(_ message: VNCControlMessage) {
        guard !isCurrentlyClosed() else { return }
        switch message.kind {
        case "close":
            close()
        case "text", "key", "pointer", "wheel":
            processInputWhenReady(message)
        case "visibility":
            guard let visible = message.visible else { return }
            setVisible(visible)
        default:
            break
        }
    }

    private func processInputWhenReady(_ message: VNCControlMessage) {
        let decision = inputLock.withLock { () -> PendingInputDecision in
            if isRemoteInputReady { return .process }
            return pendingInputMessages.append(message) ? .queued : .failed
        }
        switch decision {
        case .process:
            processInput(message)
        case .queued:
            break
        case .failed:
            failInputQueueFull()
        }
    }

    private func processInput(_ message: VNCControlMessage) {
        switch message.kind {
        case "text":
            guard let text = message.text else { return }
            withConnection { connection in
                for character in text {
                    let keys: [VNCKeyCode]
                    switch character {
                    case "\n", "\r":
                        keys = [.return]
                    case "\t":
                        keys = [.tab]
                    case "\u{7f}", "\u{8}":
                        keys = [.delete]
                    default:
                        keys = VNCKeyCode.keyCodesFrom(characters: String(character))
                    }
                    for key in keys {
                        connection.keyDown(key)
                        connection.keyUp(key)
                    }
                }
            }
        case "key":
            guard let keyCodeValue = message.keyCode,
                  let isDown = message.isDown,
                  let keyCode = UInt16(exactly: keyCodeValue) else {
                return
            }
            let remoteKeys = Self.remoteKeys(forMacKeyCode: keyCode, text: message.text)
            guard !remoteKeys.isEmpty else { return }
            withConnection { connection in
                for remoteKey in remoteKeys {
                    if isDown {
                        connection.keyDown(remoteKey)
                    } else {
                        connection.keyUp(remoteKey)
                    }
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
        case "wheel":
            guard let x = message.x,
                  let y = message.y,
                  let wheelRaw = message.wheel,
                  let wheel = VNCMouseWheel(rawValue: wheelRaw) else {
                return
            }
            let rawSteps = message.steps ?? 1
            guard rawSteps > 0 else { return }
            let clampedX = UInt16(max(0, min(UInt16.max.intValue, x)))
            let clampedY = UInt16(max(0, min(UInt16.max.intValue, y)))
            let steps = UInt32(min(256, rawSteps))
            withConnection { connection in
                connection.mouseWheel(wheel, x: clampedX, y: clampedY, steps: steps)
            }
        default:
            break
        }
    }

    private static func remoteKeys(forMacKeyCode keyCode: UInt16, text: String?) -> [VNCKeyCode] {
        if let directKey = VNCKeyCode.from(cgKeyCode: CGKeyCode(keyCode)) {
            return [directKey]
        }
        if let text, !text.isEmpty {
            let keys = VNCKeyCode.keyCodesFrom(characters: text)
            if !keys.isEmpty {
                return keys
            }
        }
        if let fallbackText = VNCMacKeyCodeTranslator.printableCharacters(forKeyCode: Int(keyCode)) {
            return VNCKeyCode.keyCodesFrom(characters: fallbackText)
        }
        return []
    }

    func close() {
        guard markClosed() else { return }
        inputLock.withLock {
            isRemoteInputReady = false
            pendingInputMessages.removeAll(keepingCapacity: false)
        }
        runOnConnectionQueue { [weak self] in
            self?.withConnection { $0.disconnect() }
        }
        signalTerminated()
    }

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        _ = connection
        runOnConnectionQueue { [weak self] in
            self?.connectionOnConnectionQueue(stateDidChange: connectionState)
        }
    }

    private func connectionOnConnectionQueue(stateDidChange connectionState: VNCConnection.ConnectionState) {
        if connectionState.status == .disconnected,
           let error = connectionState.error {
            failConnection(error: error)
            return
        }

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
            inputLock.withLock {
                isRemoteInputReady = false
                pendingInputMessages.removeAll(keepingCapacity: false)
            }
            signalTerminated()
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
        _ = connection
        runOnConnectionQueue { [weak self] in
            self?.connectionOnConnectionQueue(didCreateFramebuffer: framebuffer)
        }
    }

    private func connectionOnConnectionQueue(didCreateFramebuffer framebuffer: VNCFramebuffer) {
        sendControl(VNCControlMessage(
            kind: "size",
            sessionName: request.sessionName,
            width: Int(framebuffer.size.width),
            height: Int(framebuffer.size.height)
        ))
        flushPendingInputMessages()
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        _ = connection
        runOnConnectionQueue { [weak self] in
            self?.connectionOnConnectionQueue(didResizeFramebuffer: framebuffer)
        }
    }

    private func connectionOnConnectionQueue(didResizeFramebuffer framebuffer: VNCFramebuffer) {
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
        _ = connection
        enqueueUpdateFrameIfVisible(framebuffer: framebuffer, x: x, y: y, width: width, height: height)
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        _ = cursor
    }

    private func setVisible(_ visible: Bool) {
        frameSnapshotLock.withLock {
            guard let refreshSequence = stateLock.withLock({ frameGate.setVisible(visible) }) else { return }
            guard let framebuffer = currentFramebuffer() else { return }
            let width = UInt16(clamping: Int(framebuffer.size.width))
            let height = UInt16(clamping: Int(framebuffer.size.height))
            guard let snapshot = snapshotFrame(framebuffer: framebuffer, sequence: refreshSequence, x: 0, y: 0, width: width, height: height) else {
                failProtocolError()
                return
            }
            sendFrame(snapshot)
        }
    }

    private func enqueueUpdateFrameIfVisible(
        framebuffer: VNCFramebuffer,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) {
        frameSnapshotLock.withLock {
            guard let nextSequence = stateLock.withLock({ frameGate.nextUpdateSequence() }) else { return }
            guard let snapshot = snapshotFrame(framebuffer: framebuffer, sequence: nextSequence, x: x, y: y, width: width, height: height) else {
                failProtocolError()
                return
            }
            sendFrame(snapshot)
        }
    }

    private func snapshotFrame(
        framebuffer: VNCFramebuffer,
        sequence: UInt64,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) -> FrameSnapshot? {
        guard !isCurrentlyClosed() else { return nil }
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
            return nil
        }
        guard byteCount > 0 else { return nil }

        let header = VNCFrameHeader(
            sequence: sequence,
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
            return nil
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
        return FrameSnapshot(header: header, payload: payload)
    }

    private func sendFrame(_ snapshot: FrameSnapshot) {
        do {
            try channel.send(try VNCIPCCodec.encodeFrame(header: snapshot.header, payload: snapshot.payload))
        } catch {
            failProtocolError()
        }
    }

    private func sendControl(_ message: VNCControlMessage) {
        do {
            try channel.send(try VNCIPCCodec.encodeControl(message))
        } catch {
            close()
        }
    }

    private func failConnection(error: Error) {
        guard markClosed() else { return }
        setExitCode(HelperExit.connection.rawValue)
        inputLock.withLock {
            isRemoteInputReady = false
            pendingInputMessages.removeAll(keepingCapacity: false)
        }
        sendControl(VNCControlMessage(
            kind: "state",
            sessionName: request.sessionName,
            state: "failed",
            errorCode: "connectionFailed"
        ))
        logConnectionFailure(error)
        signalTerminated()
    }

    private func failInputQueueFull() {
        guard markClosed() else { return }
        setExitCode(HelperExit.inputQueueFull.rawValue)
        inputLock.withLock {
            isRemoteInputReady = false
            pendingInputMessages.removeAll(keepingCapacity: false)
        }
        sendControl(VNCControlMessage(
            kind: "state",
            sessionName: request.sessionName,
            state: "failed",
            errorCode: "inputQueueFull"
        ))
        signalTerminated()
    }

    private func failProtocolError() {
        guard markClosed() else { return }
        setExitCode(HelperExit.protocolError.rawValue)
        inputLock.withLock {
            isRemoteInputReady = false
            pendingInputMessages.removeAll(keepingCapacity: false)
        }
        sendControl(VNCControlMessage(
            kind: "state",
            sessionName: request.sessionName,
            state: "failed",
            errorCode: "helperProtocolFailed"
        ))
        signalTerminated()
    }

    private func logConnectionFailure(_ error: Error) {
        var sanitized = String(describing: error)
        if !request.password.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: request.password, with: "[redacted]")
        }
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fputs("cmux-vnc-helper connection failed: \(String(trimmed.prefix(500)))\n", stderr)
    }

    private func setExitCode(_ exitCode: Int32) {
        exitCodeLock.withLock {
            if requestedExitCode == 0 {
                requestedExitCode = exitCode
            }
        }
    }

    private func flushPendingInputMessages() {
        let messages = inputLock.withLock { () -> [VNCControlMessage] in
            isRemoteInputReady = true
            return pendingInputMessages.drain()
        }
        for message in messages {
            processInput(message)
        }
    }

    private func withConnection(_ body: (VNCConnection) -> Void) {
        connectionLock.withLock {
            guard let connection else { return }
            body(connection)
        }
    }

    private func currentFramebuffer() -> VNCFramebuffer? {
        connectionLock.withLock { connection?.framebuffer }
    }

    private func runOnConnectionQueue(_ body: @Sendable @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: connectionQueueKey) != nil {
            body()
        } else {
            connectionQueue.async(execute: body)
        }
    }

    private func isCurrentlyClosed() -> Bool {
        stateLock.withLock { isClosed }
    }

    private func markClosed() -> Bool {
        stateLock.withLock {
            if isClosed { return false }
            isClosed = true
            return true
        }
    }

    private func signalTerminated() {
        let handler = terminationLock.withLock { () -> (() -> Void)? in
            if isTerminated { return nil }
            isTerminated = true
            return terminationHandler
        }
        handler?()
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
    disableSIGPIPE(on: fd)
    return fd
}

private func disableSIGPIPE(on fd: Int32) {
    var value: Int32 = 1
    withUnsafePointer(to: &value) { pointer in
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            pointer,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
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

private func parseConnectionArguments(arguments: [String]) -> (
    socketPath: String?,
    inheritedFileDescriptor: Int32?,
    fake: Bool,
    isValid: Bool
) {
    func optionValue(after index: Int) -> String? {
        guard index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
        return value
    }

    var socketPath: String?
    var inheritedFileDescriptor: Int32?
    var fake = false
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--socket":
            guard let value = optionValue(after: index) else {
                return (socketPath, inheritedFileDescriptor, fake, false)
            }
            socketPath = value
            index += 1
        case "--fd":
            guard let value = optionValue(after: index),
                  let fileDescriptor = Int32(value),
                  fileDescriptor >= 0 else {
                return (socketPath, inheritedFileDescriptor, fake, false)
            }
            inheritedFileDescriptor = fileDescriptor
            index += 1
        case "--fake":
            fake = true
        default:
            break
        }
        index += 1
    }
    return (socketPath, inheritedFileDescriptor, fake, true)
}

let parsed = parseConnectionArguments(arguments: CommandLine.arguments)
guard parsed.isValid,
      parsed.inheritedFileDescriptor != nil || parsed.socketPath != nil else {
    fputs("usage: cmux-vnc-helper (--fd <fd> | --socket <path>) [--fake]\n", stderr)
    exit(HelperExit.usage.rawValue)
}

do {
    let fd: Int32
    if let inheritedFileDescriptor = parsed.inheritedFileDescriptor {
        fd = inheritedFileDescriptor
        disableSIGPIPE(on: fd)
    } else if let socketPath = parsed.socketPath {
        fd = try connectUnixSocket(path: socketPath)
    } else {
        exit(HelperExit.usage.rawValue)
    }
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
    guard let runLoop = CFRunLoopGetCurrent() else {
        exit(HelperExit.protocolError.rawValue)
    }
    var terminationSourceContext = CFRunLoopSourceContext()
    terminationSourceContext.info = Unmanaged.passUnretained(runLoop).toOpaque()
    terminationSourceContext.perform = { info in
        guard let info else { return }
        let runLoop = Unmanaged<CFRunLoop>.fromOpaque(info).takeUnretainedValue()
        CFRunLoopStop(runLoop)
    }
    guard let terminationSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &terminationSourceContext) else {
        exit(HelperExit.protocolError.rawValue)
    }
    CFRunLoopAddSource(runLoop, terminationSource, .defaultMode)
    controller.setTerminationHandler {
        CFRunLoopSourceSignal(terminationSource)
        CFRunLoopWakeUp(runLoop)
    }
    controller.start()
    let readerThread = Thread {
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
    readerThread.name = "cmux-vnc-helper-ipc-reader"
    readerThread.start()
    if !controller.hasTerminated {
        CFRunLoopRun()
    }
    CFRunLoopRemoveSource(runLoop, terminationSource, .defaultMode)
    exit(controller.exitCode)
} catch {
    fputs("cmux-vnc-helper socket error\n", stderr)
    exit(HelperExit.socket.rawValue)
}

private extension UInt16 {
    var intValue: Int { Int(self) }
}
