import Foundation

/// An event emitted by ``RFBClient`` as the session progresses. Delivered on an
/// `AsyncStream`; consumers (the view) render frames and reflect state.
public enum VNCClientEvent: Sendable, Equatable {
    case connecting
    case connected(width: Int, height: Int, name: String)
    case frame(VNCFrameSnapshot)
    case resized(width: Int, height: Int)
    case bell
    case serverCutText(String)
    case disconnected(RFBError?)
}

/// A pointer button bit for `PointerEvent`.
public struct VNCButtonMask: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = VNCButtonMask(rawValue: 1 << 0)
    public static let middle = VNCButtonMask(rawValue: 1 << 1)
    public static let right = VNCButtonMask(rawValue: 1 << 2)
    public static let wheelUp = VNCButtonMask(rawValue: 1 << 3)
    public static let wheelDown = VNCButtonMask(rawValue: 1 << 4)
}

/// Drives a single RFB session over a transport: handshake, format/encoding
/// negotiation, the framebuffer-update loop, and outbound input. Owns its
/// ``Framebuffer`` and never shares it; the UI receives `Sendable` snapshots.
public actor RFBClient {
    private let transport: NWConnectionTransport
    private let endpoint: VNCEndpoint
    private var framebuffer = Framebuffer(width: 0, height: 0)
    private var running = false
    private var continuation: AsyncStream<VNCClientEvent>.Continuation?

    /// Encodings cmux advertises, most-preferred first. Hextile and RRE shrink
    /// most desktop updates; CopyRect makes scrolling cheap; Raw is the
    /// universal fallback; DesktopSize lets the server resize us.
    private static let advertisedEncodings: [RFBClientMessage.Encoding] = [
        .copyRect, .hextile, .rre, .raw, .desktopSize,
    ]

    public init(endpoint: VNCEndpoint) {
        self.endpoint = endpoint
        self.transport = NWConnectionTransport(host: endpoint.host, port: endpoint.port)
    }

    /// Starts the session and returns a stream of events. Cancelling the stream
    /// (or calling ``stop()``) tears the connection down.
    public func start() -> AsyncStream<VNCClientEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.stop() }
            }
        }
    }

    public func stop() async {
        running = false
        await transport.close()
        continuation?.finish()
        continuation = nil
    }

    // MARK: Input

    public func sendPointer(buttons: VNCButtonMask, x: Int, y: Int) async {
        let clampedX = UInt16(clamping: max(0, x))
        let clampedY = UInt16(clamping: max(0, y))
        try? await transport.write(RFBClientMessage.pointerEvent(buttonMask: buttons.rawValue, x: clampedX, y: clampedY))
    }

    public func sendKey(keysym: UInt32, down: Bool) async {
        try? await transport.write(RFBClientMessage.keyEvent(keysym: keysym, down: down))
    }

    public func sendCutText(_ text: String) async {
        try? await transport.write(RFBClientMessage.clientCutText(text))
    }

    /// A scroll "click": press then release a wheel button.
    public func sendScroll(up: Bool, x: Int, y: Int, ticks: Int = 1) async {
        let button: VNCButtonMask = up ? .wheelUp : .wheelDown
        let cx = UInt16(clamping: max(0, x))
        let cy = UInt16(clamping: max(0, y))
        for _ in 0 ..< max(1, ticks) {
            try? await transport.write(RFBClientMessage.pointerEvent(buttonMask: button.rawValue, x: cx, y: cy))
            try? await transport.write(RFBClientMessage.pointerEvent(buttonMask: 0, x: cx, y: cy))
        }
    }

    // MARK: Session loop

    private func run(_ continuation: AsyncStream<VNCClientEvent>.Continuation) async {
        running = true
        continuation.yield(.connecting)
        do {
            try await transport.connect()
            let serverInit = try await RFBHandshake().negotiate(
                source: transport,
                sink: transport,
                password: endpoint.password,
                username: endpoint.username
            )
            framebuffer = Framebuffer(width: serverInit.width, height: serverInit.height)

            try await transport.write(RFBClientMessage.setPixelFormat(.cmuxBGRX))
            try await transport.write(RFBClientMessage.setEncodings(Self.advertisedEncodings))

            continuation.yield(.connected(width: serverInit.width, height: serverInit.height, name: serverInit.name))

            try await requestUpdate(incremental: false)

            let decoder = RFBRectangleDecoder()
            while running, !Task.isCancelled {
                try await readServerMessage(decoder: decoder, continuation: continuation)
            }
            continuation.yield(.disconnected(nil))
        } catch let error as RFBError {
            continuation.yield(.disconnected(error))
        } catch {
            continuation.yield(.disconnected(.transport(error.localizedDescription)))
        }
        running = false
        await transport.close()
        continuation.finish()
    }

    private func requestUpdate(incremental: Bool) async throws {
        guard framebuffer.width > 0, framebuffer.height > 0 else { return }
        try await transport.write(RFBClientMessage.framebufferUpdateRequest(
            incremental: incremental,
            x: 0,
            y: 0,
            width: UInt16(clamping: framebuffer.width),
            height: UInt16(clamping: framebuffer.height)
        ))
    }

    private func readServerMessage(
        decoder: RFBRectangleDecoder,
        continuation: AsyncStream<VNCClientEvent>.Continuation
    ) async throws {
        let messageType = try await transport.readUInt8()
        switch messageType {
        case 0:
            try await readFramebufferUpdate(decoder: decoder, continuation: continuation)
        case 1: // SetColourMapEntries — ignored (we use true-colour).
            _ = try await transport.readUInt8() // padding
            _ = try await transport.readUInt16() // first colour
            let count = try await transport.readUInt16()
            if count > 0 { _ = try await transport.readExactly(Int(count) * 6) }
        case 2: // Bell
            continuation.yield(.bell)
        case 3: // ServerCutText
            _ = try await transport.readExactly(3) // padding
            let text = try await transport.readLengthPrefixedString()
            continuation.yield(.serverCutText(text))
        default:
            throw RFBError.protocolViolation("unknown server message \(messageType)")
        }
    }

    private func readFramebufferUpdate(
        decoder: RFBRectangleDecoder,
        continuation: AsyncStream<VNCClientEvent>.Continuation
    ) async throws {
        _ = try await transport.readUInt8() // padding
        let rectangleCount = try await transport.readUInt16()
        var didResize = false
        for _ in 0 ..< rectangleCount {
            let header = try await transport.readRectangleHeader()
            let previousWidth = framebuffer.width
            let previousHeight = framebuffer.height
            try await decoder.decode(header: header, from: transport, into: framebuffer)
            if framebuffer.width != previousWidth || framebuffer.height != previousHeight {
                didResize = true
            }
        }
        if didResize {
            continuation.yield(.resized(width: framebuffer.width, height: framebuffer.height))
        }
        continuation.yield(.frame(framebuffer.snapshot()))
        // Ask for the next incremental update to keep the stream flowing.
        try await requestUpdate(incremental: true)
    }
}
