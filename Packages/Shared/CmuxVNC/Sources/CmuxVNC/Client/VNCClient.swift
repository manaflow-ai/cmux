import CoreGraphics
import Foundation

/// How a session connects.
public struct VNCSessionOptions: Sendable, Equatable {
    public var credentials: VNCCredentials
    /// Leave other viewers connected (RFB `shared` flag).
    public var shared: Bool
    /// Ask for the Cursor pseudo-encoding: the server stops drawing the
    /// pointer into the framebuffer and the client draws `VNCCursor` itself,
    /// so pointer motion shows with no round trip.
    public var localCursor: Bool
    /// Encodings to advertise, most preferred first; nil for the default list.
    public var encodings: [RFBEncoding]?

    public init(credentials: VNCCredentials = VNCCredentials(), shared: Bool = true, localCursor: Bool = false,
                encodings: [RFBEncoding]? = nil) {
        self.credentials = credentials
        self.shared = shared
        self.localCursor = localCursor
        self.encodings = encodings
    }
}

/// Session events other than frames (frames have their own stream).
public enum VNCEvent: Sendable, Equatable {
    case connected(VNCServerInfo)
    case cursor(VNCCursor)
    /// The server's screens (displays) inside the framebuffer.
    case screens([VNCScreen])
    case bell
    case clipboard(String)
    /// The session ended: nil when the client disconnected on purpose.
    case disconnected(RFBError?)
}

/// Counters for a session (debug overlays, tests).
public struct VNCSessionStats: Sendable, Equatable {
    public var bytesReceived = 0
    public var updates = 0
    public var frames: UInt64 = 0
    public var rectangles = 0
    /// Rectangles per encoding raw value.
    public var rectanglesByEncoding: [Int32: Int] = [:]
    /// Time from the matching update request to the update's first byte.
    public var lastUpdateLatencyMs: Double?
    /// Time from the last update's header to its last rectangle (receive and decode).
    public var lastDecodeMs: Double?
    /// Pixels the last update covered (all its rectangles).
    public var lastUpdatePixels = 0

    public init() {}
}

/// One RFB session: handshake, the update loop and input. Frames arrive on
/// `frames` (latest wins: a slow consumer skips intermediate frames, never
/// queues them); everything else on `events`.
public actor VNCClient {
    public nonisolated let endpoint: VNCEndpoint
    public nonisolated let events: AsyncStream<VNCEvent>
    public nonisolated let frames: AsyncStream<VNCFrame>
    private let eventSink: AsyncStream<VNCEvent>.Continuation
    private let frameSink: AsyncStream<VNCFrame>.Continuation
    private let options: VNCSessionOptions
    private let transport: any RFBTransport
    private var task: Task<Void, Never>?
    private var finished = false
    private var info: VNCServerInfo?
    private var size = (width: 0, height: 0)
    private var buttons: VNCButtons = []
    private var pointer = (x: 0, y: 0)
    private var requestSentAt: ContinuousClock.Instant?
    private var statistics = VNCSessionStats()
    private var advertised: [RFBEncoding] = []

    /// `transport` defaults to TCP to `endpoint`.
    public init(endpoint: VNCEndpoint, options: VNCSessionOptions = VNCSessionOptions(), transport: (any RFBTransport)? = nil) {
        self.endpoint = endpoint
        self.options = options
        self.transport = transport ?? NetworkRFBTransport(host: endpoint.host, port: endpoint.port)
        (events, eventSink) = AsyncStream.makeStream(of: VNCEvent.self, bufferingPolicy: .bufferingNewest(256))
        (frames, frameSink) = AsyncStream.makeStream(of: VNCFrame.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts the session. Idempotent; a client connects once.
    public func connect() {
        guard task == nil, !finished else { return }
        task = Task { await self.run() }
    }

    /// Ends the session; `events` reports `.disconnected(nil)`.
    public func disconnect() {
        guard !finished else { return }
        task?.cancel()
        transport.close()
        finish(nil)
    }

    public var serverInfo: VNCServerInfo? { info }
    public var stats: VNCSessionStats { statistics }

    // MARK: Input

    /// Moves the pointer to framebuffer pixel (x, y) with `buttons` held.
    public func pointer(x: Int, y: Int, buttons: VNCButtons) async {
        pointer = (clamp(x, size.width), clamp(y, size.height))
        self.buttons = buttons.subtracting([.wheelUp, .wheelDown, .wheelLeft, .wheelRight])
        await send(RFBClientMessage.pointerEvent(buttons: self.buttons.rawValue, x: pointer.x, y: pointer.y))
    }

    /// Moves the pointer, keeping the held buttons.
    public func movePointer(x: Int, y: Int) async {
        await pointer(x: x, y: y, buttons: buttons)
    }

    /// Presses or releases `button` at the current position.
    public func button(_ button: VNCButtons, down: Bool) async {
        await pointer(x: pointer.x, y: pointer.y, buttons: down ? buttons.union(button) : buttons.subtracting(button))
    }

    /// Wheel clicks at the current position: positive `dy` scrolls content
    /// up (wheel up), positive `dx` scrolls left.
    public func scroll(dx: Int, dy: Int) async {
        var bytes: [UInt8] = []
        let steps: [(VNCButtons, Int)] = [(dy > 0 ? .wheelUp : .wheelDown, abs(dy)), (dx > 0 ? .wheelLeft : .wheelRight, abs(dx))]
        for (wheel, count) in steps where count > 0 {
            for _ in 0 ..< min(count, 50) {
                bytes += RFBClientMessage.pointerEvent(buttons: buttons.union(wheel).rawValue, x: pointer.x, y: pointer.y)
                bytes += RFBClientMessage.pointerEvent(buttons: buttons.rawValue, x: pointer.x, y: pointer.y)
            }
        }
        await send(bytes)
    }

    public func key(_ keysym: VNCKeysym, down: Bool) async {
        await send(RFBClientMessage.keyEvent(keysym: keysym.rawValue, down: down))
    }

    /// Presses and releases each character's key.
    public func type(_ text: String) async {
        var bytes: [UInt8] = []
        for character in text {
            let keysym = VNCKeysym(character: character).rawValue
            bytes += RFBClientMessage.keyEvent(keysym: keysym, down: true)
            bytes += RFBClientMessage.keyEvent(keysym: keysym, down: false)
        }
        await send(bytes)
    }

    /// Presses `modifiers` in order, taps `key`, then releases in reverse.
    public func chord(_ modifiers: [VNCKeysym], _ key: VNCKeysym) async {
        var bytes: [UInt8] = []
        for modifier in modifiers { bytes += RFBClientMessage.keyEvent(keysym: modifier.rawValue, down: true) }
        bytes += RFBClientMessage.keyEvent(keysym: key.rawValue, down: true)
        bytes += RFBClientMessage.keyEvent(keysym: key.rawValue, down: false)
        for modifier in modifiers.reversed() { bytes += RFBClientMessage.keyEvent(keysym: modifier.rawValue, down: false) }
        await send(bytes)
    }

    /// Sends the local clipboard to the server (Latin-1).
    public func setClipboard(_ text: String) async {
        await send(RFBClientMessage.clientCutText(text))
    }

    /// Asks for a full, non-incremental refresh.
    public func refresh() async {
        guard size.width > 0 else { return }
        await send(RFBClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: size.width, height: size.height))
    }

    private func clamp(_ value: Int, _ limit: Int) -> Int {
        max(0, min(value, max(0, limit - 1)))
    }

    private func send(_ bytes: [UInt8]) async {
        guard info != nil, !finished, !bytes.isEmpty else { return }
        try? await transport.send(bytes)
    }

    // MARK: Session

    private func run() async {
        let reader = RFBReader(transport: transport)
        do {
            try await transport.open()
            let handshake = RFBHandshake(credentials: options.credentials, shared: options.shared)
            let info = try await handshake.run(reader: reader, transport: transport)
            self.info = info
            let framebuffer = Framebuffer(width: info.width, height: info.height)
            size = (info.width, info.height)
            try await transport.send(RFBClientMessage.setPixelFormat(.bgrx))
            advertised = options.encodings ?? RFBEncoding.advertised(localCursor: options.localCursor)
            try await transport.send(RFBClientMessage.setEncodings(advertised))
            eventSink.yield(.connected(info))
            try await request(incremental: false)
            let decoder = RFBRectangleDecoder()
            let publisher = FramePublisher()
            while !Task.isCancelled {
                let type = try await reader.u8()
                switch type {
                case 0:
                    try await update(reader: reader, decoder: decoder, framebuffer: framebuffer, publisher: publisher)
                case 1:
                    try await reader.skip(3)
                    let count = Int(try await reader.u16())
                    try await reader.skip(count * 6)
                case 2:
                    eventSink.yield(.bell)
                case 3:
                    try await reader.skip(3)
                    // ServerCutText is Latin-1 (RFC 6143 7.6.4).
                    let length = Int(try await reader.u32())
                    guard length <= 16 << 20 else { throw RFBError.protocolViolation("clipboard of \(length) bytes") }
                    let bytes = try await reader.bytes(length)
                    eventSink.yield(.clipboard(String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))))
                default:
                    throw RFBError.protocolViolation("server message \(type)")
                }
                statistics.bytesReceived = reader.bytesReceived
            }
        } catch let error as RFBError {
            finish(Task.isCancelled ? nil : error)
        } catch {
            finish(Task.isCancelled ? nil : .transport(String(describing: error)))
        }
        transport.close()
    }

    private func request(incremental: Bool) async throws {
        requestSentAt = .now
        try await transport.send(RFBClientMessage.framebufferUpdateRequest(
            incremental: incremental, x: 0, y: 0, width: size.width, height: size.height))
    }

    private func update(reader: RFBReader, decoder: RFBRectangleDecoder, framebuffer: Framebuffer, publisher: FramePublisher) async throws {
        try await reader.skip(1)
        let count = Int(try await reader.u16())
        // 0xFFFF means "until LastRect" only when LastRect was advertised.
        let untilLastRect = count == 0xFFFF && advertised.contains(.lastRect)
        if let sent = requestSentAt {
            statistics.lastUpdateLatencyMs = Self.milliseconds(sent.duration(to: .now))
        }
        // Ask for the next update before decoding this one, so the server
        // prepares it while this one decodes (one request in flight).
        try await request(incremental: true)
        let started = ContinuousClock.now
        var resized = false
        var covered = 0
        var index = 0
        var ended = false
        // A count of 0xFFFF means "until LastRect" when the server supports it.
        while !ended, untilLastRect || index < count {
            let header = RFBRectangleHeader(
                x: Int(try await reader.u16()), y: Int(try await reader.u16()),
                width: Int(try await reader.u16()), height: Int(try await reader.u16()),
                encoding: try await reader.s32())
            index += 1
            statistics.rectangles += 1
            if header.encoding >= 0 { covered += header.width * header.height }
            statistics.rectanglesByEncoding[header.encoding, default: 0] += 1
            switch try await decoder.decode(header, reader: reader, into: framebuffer) {
            case .drew:
                break
            case .resized:
                resized = true
            case let .cursor(cursor):
                eventSink.yield(.cursor(cursor))
            case let .screens(screens):
                let width = framebuffer.width, height = framebuffer.height
                if width != size.width { resized = true }
                if height != size.height { resized = true }
                eventSink.yield(.screens(screens))
            case .lastRect:
                ended = true
            }
        }
        statistics.updates += 1
        statistics.lastUpdatePixels = covered
        statistics.lastDecodeMs = Self.milliseconds(started.duration(to: .now))
        if resized {
            size = (framebuffer.width, framebuffer.height)
            try await request(incremental: false)
        }
        let dirty = framebuffer.takeDirty()
        guard !dirty.isNull, let frame = publisher.publish(framebuffer, dirty: dirty) else { return }
        statistics.frames = frame.sequence
        frameSink.yield(frame)
    }

    private func finish(_ error: RFBError?) {
        guard !finished else { return }
        finished = true
        eventSink.yield(.disconnected(error))
        eventSink.finish()
        frameSink.finish()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
