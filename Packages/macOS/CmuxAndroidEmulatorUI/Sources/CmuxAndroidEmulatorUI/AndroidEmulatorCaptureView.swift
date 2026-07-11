import AppKit
import CmuxAndroidEmulator
import CoreGraphics
import Darwin
import SwiftUI

struct AndroidEmulatorCaptureView: NSViewRepresentable {
    let controller: AndroidEmulatorPaneController
    let isVisible: Bool
    let sdkRootURL: URL
    let displaySize: AndroidEmulatorDisplaySize
    let retryGeneration: Int

    func makeNSView(context: Context) -> AndroidEmulatorCaptureNSView {
        let view = AndroidEmulatorCaptureNSView()
        controller.attachCaptureView(view)
        return view
    }

    func updateNSView(_ view: AndroidEmulatorCaptureNSView, context: Context) {
        controller.attachCaptureView(view)
        view.setDisplaySize(displaySize)
        view.setVisible(
            isVisible,
            avdName: controller.avdName,
            serial: controller.serial,
            sdkRootURL: sdkRootURL,
            displaySize: displaySize,
            retryGeneration: retryGeneration,
            onStarted: controller.clearCaptureError,
            onError: controller.reportCaptureError
        )
    }

    static func dismantleNSView(_ view: AndroidEmulatorCaptureNSView, coordinator: ()) {
        view.stopCapture()
    }
}

@MainActor
final class AndroidEmulatorCaptureNSView: NSView {
    private let displayLayer = CALayer()
    private var bridge: AndroidEmulatorBridgeSession?
    private var bridgeTask: Task<Void, Never>?
    private var configuration: CaptureConfiguration?
    private var displaySize = AndroidEmulatorDisplaySize(width: 1080, height: 1920)
    private var zoomScale: CGFloat = 1
    private var latestImage: CGImage?
    private var retainedSlots: [Int] = []
    private var frameIsBottomUp = false
    private var activeTouchPoint: (x: Int, y: Int)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        displayLayer.backgroundColor = NSColor.clear.cgColor
        displayLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layoutDisplayLayer()
    }

    func setDisplaySize(_ size: AndroidEmulatorDisplaySize) {
        guard displaySize != size else { return }
        displaySize = size
        needsLayout = true
    }

    func setZoomScale(_ scale: CGFloat) {
        guard zoomScale != scale else { return }
        zoomScale = scale
        needsLayout = true
    }

    func setVisible(
        _ visible: Bool,
        avdName: String,
        serial: String,
        sdkRootURL: URL,
        displaySize: AndroidEmulatorDisplaySize,
        retryGeneration: Int,
        onStarted: @escaping () -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        let next = CaptureConfiguration(
            avdName: avdName,
            serial: serial,
            sdkRootURL: sdkRootURL,
            displaySize: displaySize,
            retryGeneration: retryGeneration
        )
        guard visible else {
            stopCapture()
            return
        }
        guard configuration != next else { return }
        stopCapture()
        configuration = next
        bridgeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let bridge = try await AndroidEmulatorBridgeSession.start(
                    avdName: avdName,
                    serial: serial,
                    displaySize: displaySize,
                    onFrame: { [weak self] image, slot, bottomUp in
                        self?.display(image, from: slot, bottomUp: bottomUp)
                    },
                    onError: onError
                )
                guard !Task.isCancelled else {
                    bridge.stop()
                    return
                }
                self.bridge = bridge
                onStarted()
            } catch is CancellationError {
                return
            } catch {
                onError(error)
            }
        }
    }

    func stopCapture() {
        configuration = nil
        bridgeTask?.cancel()
        bridgeTask = nil
        if let activeTouchPoint {
            bridge?.sendTouch(x: activeTouchPoint.x, y: activeTouchPoint.y, phase: "up")
            self.activeTouchPoint = nil
        }
        retainedSlots.removeAll()
        latestImage = nil
        displayLayer.contents = nil
        bridge?.stop()
        bridge = nil
    }

    func saveScreenshot() {
        guard let latestImage else { return }
        let screenshotImage = frameIsBottomUp ? Self.verticallyFlippedCopy(latestImage) : latestImage
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(configuration?.avdName ?? "android")-screenshot.png"
        panel.title = String(
            localized: "androidEmulator.screenshot.title",
            defaultValue: "Save Android Screenshot",
            bundle: .module
        )
        panel.prompt = String(
            localized: "androidEmulator.screenshot.save",
            defaultValue: "Save",
            bundle: .module
        )
        guard panel.runModal() == .OK, let url = panel.url,
              let data = NSBitmapImageRep(cgImage: screenshotImage).representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func verticallyFlippedCopy(_ image: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    func showVendorWindow() {
        bridge?.showExtendedControls()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = androidPoint(for: convert(event.locationInWindow, from: nil)) else { return }
        activeTouchPoint = point
        bridge?.sendTouch(x: point.x, y: point.y, phase: "down")
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTouchPoint != nil else { return }
        let point = clampedAndroidPoint(for: convert(event.locationInWindow, from: nil))
        activeTouchPoint = point
        bridge?.sendTouch(x: point.x, y: point.y, phase: "move")
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTouchPoint != nil else { return }
        let point = clampedAndroidPoint(for: convert(event.locationInWindow, from: nil))
        activeTouchPoint = nil
        bridge?.sendTouch(x: point.x, y: point.y, phase: "up")
    }

    override func keyDown(with event: NSEvent) {
        if let key = Self.webKey(for: event) {
            bridge?.sendKey(key: key)
        } else if let characters = event.characters, !characters.isEmpty {
            bridge?.sendText(characters)
        } else {
            super.keyDown(with: event)
        }
    }

    private func display(_ image: CGImage, from slot: Int, bottomUp: Bool) {
        retainedSlots.append(slot)
        latestImage = image
        if frameIsBottomUp != bottomUp {
            frameIsBottomUp = bottomUp
            layoutDisplayLayer()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contents = image
        CATransaction.commit()
        if retainedSlots.count > 2 {
            bridge?.release(slot: retainedSlots.removeFirst())
        }
    }

    private static func webKey(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76: "Enter"
        case 48: "Tab"
        case 51: "Backspace"
        case 53: "Escape"
        case 123: "ArrowLeft"
        case 124: "ArrowRight"
        case 125: "ArrowDown"
        case 126: "ArrowUp"
        default: nil
        }
    }

    private func layoutDisplayLayer() {
        let aspect = CGFloat(displaySize.width) / CGFloat(displaySize.height)
        let fitWidth = min(bounds.width, bounds.height * aspect)
        let fitHeight = fitWidth / aspect
        let size = CGSize(width: fitWidth * zoomScale, height: fitHeight * zoomScale)
        displayLayer.bounds = CGRect(origin: .zero, size: size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(CGAffineTransform(scaleX: 1, y: frameIsBottomUp ? -1 : 1))
    }

    private func androidPoint(for point: CGPoint) -> (x: Int, y: Int)? {
        guard displayLayer.frame.contains(point), displayLayer.frame.width > 0, displayLayer.frame.height > 0 else {
            return nil
        }
        let normalizedX = (point.x - displayLayer.frame.minX) / displayLayer.frame.width
        let normalizedY = 1 - ((point.y - displayLayer.frame.minY) / displayLayer.frame.height)
        return (
            min(displaySize.width - 1, max(0, Int(normalizedX * CGFloat(displaySize.width)))),
            min(displaySize.height - 1, max(0, Int(normalizedY * CGFloat(displaySize.height))))
        )
    }

    private func clampedAndroidPoint(for point: CGPoint) -> (x: Int, y: Int) {
        let normalizedX = min(1, max(0, (point.x - displayLayer.frame.minX) / max(1, displayLayer.frame.width)))
        let normalizedY = min(
            1,
            max(0, 1 - ((point.y - displayLayer.frame.minY) / max(1, displayLayer.frame.height)))
        )
        return (
            min(displaySize.width - 1, max(0, Int(normalizedX * CGFloat(displaySize.width)))),
            min(displaySize.height - 1, max(0, Int(normalizedY * CGFloat(displaySize.height))))
        )
    }

    private struct CaptureConfiguration: Equatable {
        let avdName: String
        let serial: String
        let sdkRootURL: URL
        let displaySize: AndroidEmulatorDisplaySize
        let retryGeneration: Int
    }
}

@MainActor
private final class AndroidEmulatorBridgeSession {
    private static let protocolVersion = 1
    private static let renderWidth = 720

    private let process: Process
    private let handle: FileHandle
    private let directoryURL: URL
    private let mappedFrames: AndroidMappedFrameBuffer
    private let onFrame: (CGImage, Int, Bool) -> Void
    private let onError: (any Error) -> Void
    private var readTask: Task<Void, Never>?
    private var stopped = false
    private let encoder = JSONEncoder()

    private init(
        process: Process,
        handle: FileHandle,
        directoryURL: URL,
        mappedFrames: AndroidMappedFrameBuffer,
        onFrame: @escaping (CGImage, Int, Bool) -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        self.process = process
        self.handle = handle
        self.directoryURL = directoryURL
        self.mappedFrames = mappedFrames
        self.onFrame = onFrame
        self.onError = onError
    }

    static func start(
        avdName: String,
        serial: String,
        displaySize: AndroidEmulatorDisplaySize,
        onFrame: @escaping (CGImage, Int, Bool) -> Void,
        onError: @escaping (any Error) -> Void
    ) async throws -> AndroidEmulatorBridgeSession {
        let helperURL = try AndroidEmulatorBridgeLocator().executableURL()
        let directoryURL = AndroidEmulatorBridgeRuntimePath.directoryURL(identifier: UUID())
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let socketURL = directoryURL.appendingPathComponent("bridge.sock")
        let sharedMemoryURL = directoryURL.appendingPathComponent("frames.bin")
        let renderHeight = max(1, Int(
            (Double(renderWidth) * Double(displaySize.height) / Double(displaySize.width)).rounded()
        ))

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--avd", avdName,
            "--serial", serial,
            "--socket", socketURL.path,
            "--shared-memory", sharedMemoryURL.path,
            "--width", String(renderWidth),
            "--height", String(renderHeight),
        ]
        do {
            try process.run()
            let handle = try await AndroidUnixSocket.connect(path: socketURL.path)
            let helloData = try await AndroidUnixSocket.readLine(from: handle)
            let hello = try JSONDecoder().decode(AndroidBridgeEvent.self, from: helloData)
            let expectedSlotSize = renderWidth * renderHeight * 4
            guard hello.type == "hello", hello.version == protocolVersion,
                  hello.sharedMemoryPath == sharedMemoryURL.path,
                  let slotCount = hello.slotCount, let slotSize = hello.slotSize,
                  slotCount == 3, slotSize == expectedSlotSize else {
                throw AndroidEmulatorBridgeError.incompatibleProtocol
            }
            let mappedFrames = try AndroidMappedFrameBuffer(
                path: sharedMemoryURL.path,
                slotCount: slotCount,
                slotSize: slotSize
            )
            let session = AndroidEmulatorBridgeSession(
                process: process,
                handle: handle,
                directoryURL: directoryURL,
                mappedFrames: mappedFrames,
                onFrame: onFrame,
                onError: onError
            )
            session.startReading()
            return session
        } catch {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    private func startReading() {
        let handle = self.handle
        readTask = Task.detached { [weak self, handle] in
            let decoder = JSONDecoder()
            var pending = Data()
            do {
                for try await byte in handle.bytes {
                    try Task.checkCancellation()
                    if byte == 0x0A {
                        guard !pending.isEmpty else { continue }
                        let event = try decoder.decode(AndroidBridgeEvent.self, from: pending)
                        pending.removeAll(keepingCapacity: true)
                        await self?.process(event)
                    } else {
                        pending.append(byte)
                        guard pending.count <= 64 * 1024 else {
                            throw AndroidEmulatorBridgeError.incompatibleProtocol
                        }
                    }
                }
                await self?.reportReadFailure(AndroidEmulatorBridgeError.disconnected)
            } catch is CancellationError {
                return
            } catch {
                await self?.reportReadFailure(error)
            }
        }
    }

    private func reportReadFailure(_ error: any Error) {
        if !stopped { onError(error) }
    }

    private func process(_ event: AndroidBridgeEvent) {
        guard event.type == "frame", let slot = event.slot,
              let width = event.width, let height = event.height,
              let bytesPerRow = event.bytesPerRow else {
            return
        }
        guard let image = mappedFrames.image(
            slot: slot,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) else {
            release(slot: slot)
            return
        }
        onFrame(image, slot, event.bottomUp ?? false)
    }

    func sendTouch(x: Int, y: Int, phase: String) {
        send(AndroidBridgeCommand(type: "touch", x: x, y: y, phase: phase))
    }

    func sendText(_ text: String) {
        send(AndroidBridgeCommand(type: "key", text: text))
    }

    func sendKey(key: String) {
        send(AndroidBridgeCommand(type: "key", key: key))
    }

    func showExtendedControls() {
        send(AndroidBridgeCommand(type: "showExtendedControls"))
    }

    func release(slot: Int) {
        send(AndroidBridgeCommand(type: "release", slot: slot))
    }

    private func send(_ command: AndroidBridgeCommand) {
        guard !stopped else { return }
        do {
            var data = try encoder.encode(command)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            onError(error)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        readTask?.cancel()
        readTask = nil
        try? handle.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

private struct AndroidBridgeEvent: Decodable, Sendable {
    let type: String
    var version: Int?
    var sharedMemoryPath: String?
    var slotCount: Int?
    var slotSize: Int?
    var slot: Int?
    var width: Int?
    var height: Int?
    var bytesPerRow: Int?
    var bottomUp: Bool?
}

private struct AndroidBridgeCommand: Encodable, Sendable {
    let type: String
    var slot: Int?
    var x: Int?
    var y: Int?
    var phase: String?
    var text: String?
    var key: String?

    init(
        type: String,
        slot: Int? = nil,
        x: Int? = nil,
        y: Int? = nil,
        phase: String? = nil,
        text: String? = nil,
        key: String? = nil
    ) {
        self.type = type
        self.slot = slot
        self.x = x
        self.y = y
        self.phase = phase
        self.text = text
        self.key = key
    }
}

private final class AndroidMappedFrameBuffer: @unchecked Sendable {
    private let descriptor: Int32
    private let baseAddress: UnsafeRawPointer
    private let byteCount: Int
    private let slotCount: Int
    private let slotSize: Int

    init(path: String, slotCount: Int, slotSize: Int) throws {
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw AndroidEmulatorBridgeError.systemCall("open", errno)
        }
        let byteCount = slotCount * slotSize
        guard let mapping = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0),
              mapping != MAP_FAILED else {
            Darwin.close(descriptor)
            throw AndroidEmulatorBridgeError.systemCall("mmap", errno)
        }
        self.descriptor = descriptor
        self.baseAddress = UnsafeRawPointer(mapping)
        self.byteCount = byteCount
        self.slotCount = slotCount
        self.slotSize = slotSize
    }

    func image(slot: Int, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        let (minimumBytesPerRow, rowWidthOverflow) = width.multipliedReportingOverflow(by: 4)
        let (frameBytes, frameSizeOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard (0 ..< slotCount).contains(slot), width > 0, height > 0, bytesPerRow > 0,
              !rowWidthOverflow, !frameSizeOverflow,
              bytesPerRow >= minimumBytesPerRow, frameBytes <= slotSize else {
            return nil
        }
        let bytes = baseAddress.advanced(by: slot * slotSize)
        let retainedMapping = Unmanaged.passRetained(self)
        guard let provider = CGDataProvider(
            dataInfo: retainedMapping.toOpaque(),
            data: bytes,
            size: frameBytes,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<AndroidMappedFrameBuffer>.fromOpaque(info).release()
            }
        ) else {
            retainedMapping.release()
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: baseAddress), byteCount)
        Darwin.close(descriptor)
    }
}

struct AndroidEmulatorBridgeLocator: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func executableURL() throws -> URL {
        var candidates: [URL] = []
        if let override = environment["CMUX_ANDROID_BRIDGE_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(homeDirectory.appendingPathComponent(".local/bin/cmux-android-bridge"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/cmux-android-bridge"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/cmux-android-bridge"))
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("cmux-android-bridge")
            })
        }
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw AndroidEmulatorBridgeError.helperNotInstalled
        }
        return executable
    }
}

enum AndroidEmulatorBridgeRuntimePath {
    static func directoryURL(identifier: UUID) -> URL {
        // AF_UNIX paths are capped at 104 bytes on macOS. The per-user temporary
        // directory can already consume most of that budget.
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-android-\(identifier.uuidString)", isDirectory: true)
    }
}

private enum AndroidUnixSocket {
    static func connect(path: String) async throws -> FileHandle {
        let clock = ContinuousClock()
        var lastError: (any Error)?
        for attempt in 0 ..< 40 {
            try Task.checkCancellation()
            do {
                return try await Task.detached { try connectOnce(path: path) }.value
            } catch {
                lastError = error
                guard attempt < 39 else { break }
                try await clock.sleep(for: .milliseconds(50))
            }
        }
        throw lastError ?? AndroidEmulatorBridgeError.disconnected
    }

    static func readLine(from handle: FileHandle) async throws -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw AndroidEmulatorBridgeError.systemCall("fcntl", errno)
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var line = Data()
        var byte: UInt8 = 0
        while clock.now < deadline {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A { return line }
                line.append(byte)
                guard line.count <= 64 * 1024 else {
                    throw AndroidEmulatorBridgeError.incompatibleProtocol
                }
                continue
            }
            if count == 0 { throw AndroidEmulatorBridgeError.disconnected }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                throw AndroidEmulatorBridgeError.systemCall("read", errno)
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw AndroidEmulatorBridgeError.handshakeTimedOut
    }

    private static func connectOnce(path: String) throws -> FileHandle {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AndroidEmulatorBridgeError.systemCall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            Darwin.close(descriptor)
            throw AndroidEmulatorBridgeError.socketPathTooLong
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = memcpy($0, source, bytes.count)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw AndroidEmulatorBridgeError.systemCall("connect", code)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private enum AndroidEmulatorBridgeError: LocalizedError {
    case helperNotInstalled
    case incompatibleProtocol
    case handshakeTimedOut
    case disconnected
    case socketPathTooLong
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return String(
                localized: "androidEmulator.bridge.notInstalled",
                defaultValue: "Install cmux-android-bridge to show the emulator in this pane.",
                bundle: .module
            )
        case .incompatibleProtocol:
            return String(
                localized: "androidEmulator.bridge.incompatible",
                defaultValue: "The installed Android bridge is incompatible with this version of cmux.",
                bundle: .module
            )
        case .handshakeTimedOut:
            return String(
                localized: "androidEmulator.bridge.handshakeTimedOut",
                defaultValue: "The Android bridge did not respond. Retry to start it again.",
                bundle: .module
            )
        case .disconnected:
            return String(
                localized: "androidEmulator.bridge.disconnected",
                defaultValue: "The Android bridge disconnected.",
                bundle: .module
            )
        case .socketPathTooLong:
            return String(
                localized: "androidEmulator.bridge.socketPathTooLong",
                defaultValue: "The Android bridge socket path is too long.",
                bundle: .module
            )
        case .systemCall(let operation, let code):
            let format = String(
                localized: "androidEmulator.bridge.systemCallFailed",
                defaultValue: "%1$@ failed with error %2$ld.",
                bundle: .module
            )
            return String(format: format, operation, Int(code))
        }
    }
}
