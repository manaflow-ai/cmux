import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation
import CmuxVNC
import CoreGraphics
import Foundation
import Network
import zlib

/// A loopback RFB 3.8 server over `DemoScene`, for tests and offline demos.
/// It speaks no authentication or VNC password authentication, sends Raw or
/// ZRLE rectangles, and can send the cursor shape. Never bind it beyond
/// loopback: it is a fixture, not a host.
// crash-allow: every mutable field is read and written only on `queue` (start, stop, accept, the timer and typedText all hop to it).
public final class VNCDemoServer: @unchecked Sendable {
    // @unchecked: every mutable field is confined to `queue`.
    public struct Configuration: Sendable {
        public var width: Int
        public var height: Int
        public var name: String
        /// Nil offers security type None; otherwise VNC password authentication.
        public var password: String?
        /// Animation steps per second (0 stops the bouncing tile).
        public var framesPerSecond: Int

        public init(width: Int = 1280, height: Int = 800, name: String = "cmux VNC demo", password: String? = nil,
                    framesPerSecond: Int = 30) {
            self.width = width
            self.height = height
            self.name = name
            self.password = password
            self.framesPerSecond = framesPerSecond
        }
    }

    public let configuration: Configuration
    private let queue = DispatchQueue(label: "cmux.vnc.demo-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: DemoConnection] = [:]
    private var timer: (any DispatchSourceTimer)?
    private var scene: DemoScene?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Listens on 127.0.0.1 (`port` 0 picks a free one); returns the port.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        return try await withOnceThrowingContinuation { (started: OnceContinuation<UInt16, any Error>) in
            queue.async {
                self.scene = DemoScene(width: self.configuration.width, height: self.configuration.height,
                                       animate: self.configuration.framesPerSecond > 0)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                // The first ready, failed or cancelled state answers `start`. Network calls this handler on
                // `queue` one state at a time, so dropping it there leaves no later state to answer again.
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        listener?.stateUpdateHandler = nil
                        started.resume(returning: listener?.port?.rawValue ?? 0)
                    case let .failed(error), let .waiting(error):
                        listener?.stateUpdateHandler = nil
                        started.resume(throwing: error)
                    case .cancelled:
                        // `stop()` before the listener was ready.
                        listener?.stateUpdateHandler = nil
                        started.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
                self.startTimer()
            }
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.close() }
            self.connections.removeAll()
        }
    }

    /// The text typed by viewers so far (tests).
    public func typedText() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.scene?.typed ?? "") }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let scene else { connection.cancel(); return }
        let peer = DemoConnection(connection: connection, scene: scene, configuration: configuration, queue: queue)
        let key = ObjectIdentifier(peer)
        connections[key] = peer
        scene.clients = connections.count
        peer.onClose = { [weak self] in
            self?.connections[key] = nil
            self?.scene?.clients = self?.connections.count ?? 0
        }
        peer.onSceneChange = { [weak self] rect in self?.broadcast(rect) }
        peer.start()
    }

    private func broadcast(_ rect: CGRect) {
        guard !rect.isNull else { return }
        for connection in connections.values { connection.invalidate(rect) }
    }

    private func startTimer() {
        let fps = max(1, configuration.framesPerSecond == 0 ? 1 : configuration.framesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let scene, !connections.isEmpty else { return }
            broadcast(scene.tick())
        }
        timer.resume()
        self.timer = timer
    }
}

/// One viewer: the handshake and message state machine, its pending damage
/// and whether it has an update request outstanding. Confined to the queue.
// crash-allow: confined to the server queue; the connection's handlers run on it and the server calls in only from it.
final class DemoConnection: @unchecked Sendable {
    // @unchecked: confined to the server queue.
    private enum Phase {
        case version, security, auth, clientInit, normal
    }

    private let connection: NWConnection
    private let scene: DemoScene
    private let configuration: VNCDemoServer.Configuration
    private let queue: DispatchQueue
    private var phase = Phase.version
    private var input: [UInt8] = []
    private var challenge: [UInt8] = []
    private var encodings: Set<Int32> = []
    /// Damage since the last update: separate rectangles, so distant changes
    /// (the status window and the moving tile) are not sent as one big union.
    private var pending: [CGRect] = []
    private var requested = false
    private var cursorSent = false
    private var buttons: UInt8 = 0
    private var shift = false
    private var deflater: Deflater?
    var onClose: (() -> Void)?
    var onSceneChange: ((CGRect) -> Void)?

    init(connection: NWConnection, scene: DemoScene, configuration: VNCDemoServer.Configuration, queue: DispatchQueue) {
        self.connection = connection
        self.scene = scene
        self.configuration = configuration
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed()
            default: break
            }
        }
        connection.start(queue: queue)
        send(Array("RFB 003.008\n".utf8))
        receive()
    }

    func close() {
        connection.cancel()
    }

    private func closed() {
        onClose?()
        onClose = nil
    }

    func invalidate(_ rect: CGRect) {
        add(rect)
        flush()
    }

    private func add(_ rect: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: scene.width, height: scene.height)
        var merged = rect.intersection(bounds).integral
        guard !merged.isNull, !merged.isEmpty else { return }
        // Fold in every rectangle it touches, then keep the list short.
        pending.removeAll { other in
            guard other.intersects(merged.insetBy(dx: -8, dy: -8)) else { return false }
            merged = merged.union(other)
            return true
        }
        pending.append(merged)
        if pending.count > 8 { pending = [pending.reduce(CGRect.null) { $0.union($1) }] }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { input.append(contentsOf: data) }
            process()
            if complete || error != nil { connection.cancel(); return }
            receive()
        }
    }

    private func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    // MARK: Client messages

    // A client's bytes are read as slices of what arrived: no read indexes `input`.
    private func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, input.count >= count else { return nil }
        defer { input.removeFirst(count) }
        return Array(input.prefix(count))
    }

    private func peekU16(_ offset: Int) -> Int { input.dropFirst(offset).prefix(2).bigEndian(as: UInt16.self).widened }
    private func peekU32(_ offset: Int) -> Int {
        Int(truncatingIfNeeded: input.dropFirst(offset).prefix(4).bigEndian(as: UInt32.self))
    }

    private func process() {
        while true {
            switch phase {
            case .version:
                guard take(12) != nil else { return }
                send(configuration.password == nil ? [1, 1] : [1, 2])
                phase = .security
            case .security:
                guard let chosen = take(1)?.first else { return }
                if chosen == 2, configuration.password != nil {
                    challenge = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }
                    send(challenge)
                    phase = .auth
                } else if chosen == 1, configuration.password == nil {
                    send([0, 0, 0, 0])
                    phase = .clientInit
                } else {
                    fail("unsupported security type")
                    return
                }
            case .auth:
                guard let response = take(16) else { return }
                let expected = DemoVNCAuth(password: configuration.password ?? "").response(challenge: challenge)
                guard response == expected else {
                    fail("Authentication failed")
                    return
                }
                send([0, 0, 0, 0])
                phase = .clientInit
            case .clientInit:
                guard take(1) != nil else { return }
                var bytes = DemoBytes()
                bytes.u16(scene.width)
                bytes.u16(scene.height)
                bytes.append(RFBPixelFormat.bgrx.encoded)
                let name = Array(configuration.name.utf8)
                bytes.u32(name.count)
                bytes.append(name)
                send(bytes.data)
                phase = .normal
            case .normal:
                guard let type = input.first else { return }
                switch type {
                case 0:
                    guard take(20) != nil else { return }
                case 2:
                    guard input.count >= 4 else { return }
                    let count = peekU16(2)
                    guard let bytes = take(4 + count * 4) else { return }
                    encodings = Set((0 ..< count).map { index in
                        Int32(bitPattern: bytes.dropFirst(4 + index * 4).prefix(4).bigEndian(as: UInt32.self))
                    })
                case 3:
                    guard let bytes = take(10) else { return }
                    if bytes.dropFirst(1).first == 0 { pending = [CGRect(x: 0, y: 0, width: scene.width, height: scene.height)] }
                    requested = true
                    flush()
                case 4:
                    guard let bytes = take(8) else { return }
                    let keysym = bytes.dropFirst(4).bigEndian(as: UInt32.self)
                    let down = bytes.dropFirst(1).first != 0
                    if keysym == 0xFFE1 || keysym == 0xFFE2 { shift = down }
                    onSceneChange?(scene.key(keysym, down: down, shift: shift))
                case 5:
                    guard let bytes = take(6) else { return }
                    buttons = bytes.dropFirst(1).first ?? 0
                    let x = bytes.dropFirst(2).prefix(2).bigEndian(as: UInt16.self).widened
                    let y = bytes.dropFirst(4).prefix(2).bigEndian(as: UInt16.self).widened
                    onSceneChange?(scene.pointer(x: x, y: y, leftDown: buttons & 1 != 0))
                case 6:
                    guard input.count >= 8 else { return }
                    guard take(8 + peekU32(4)) != nil else { return }
                default:
                    fail("unknown message \(type)")
                    return
                }
            }
        }
    }

    private func fail(_ reason: String) {
        var bytes = DemoBytes()
        bytes.u32(1)
        let text = Array(reason.utf8)
        bytes.u32(text.count)
        bytes.append(text)
        // Close once the reason is on the wire.
        connection.send(content: Data(bytes.data), completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    // MARK: Updates

    private func flush() {
        guard phase == .normal, requested else { return }
        let wantsCursor = encodings.contains(RFBEncoding.cursor.rawValue) && !cursorSent
        guard wantsCursor || !pending.isEmpty else { return }
        requested = false
        let damage = pending
        pending = []
        var rects: [[UInt8]] = []
        if wantsCursor {
            cursorSent = true
            rects.append(DemoCursor().rectangle())
        }
        for rect in damage {
            rects.append(encode(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height)))
        }
        var bytes = DemoBytes()
        bytes.append([0, 0])
        bytes.u16(rects.count)
        for rect in rects { bytes.append(rect) }
        send(bytes.data)
    }

    private func encode(x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var bytes = DemoBytes()
        bytes.u16(x)
        bytes.u16(y)
        bytes.u16(width)
        bytes.u16(height)
        if encodings.contains(RFBEncoding.zrle.rawValue) {
            bytes.s32(RFBEncoding.zrle.rawValue)
            let raw = ZRLEEncoder(scene: scene).encode(x: x, y: y, width: width, height: height)
            let stream = deflater ?? Deflater()
            deflater = stream
            let compressed = stream.deflate(raw)
            bytes.u32(compressed.count)
            bytes.append(compressed)
        } else {
            bytes.s32(RFBEncoding.raw.rawValue)
            for row in y ..< y + height {
                for col in x ..< x + width {
                    let pixel = scene.pixel(at: row * scene.width + col)
                    bytes.append([UInt8(pixel & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8((pixel >> 16) & 0xFF), 0])
                }
            }
        }
        return bytes.data
    }
}

struct DemoBytes {
    var data: [UInt8] = []
    mutating func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func u16(_ value: Int) { data.append(contentsOf: [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]) }
    mutating func u32(_ value: Int) {
        data.append(contentsOf: [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    mutating func s32(_ value: Int32) { u32(Int(UInt32(bitPattern: value))) }
}

/// ZRLE tiles before compression: solid tiles, plain RLE when it is smaller,
/// raw otherwise (exercises three of the client's tile decoders).
struct ZRLEEncoder {
    let scene: DemoScene

    func encode(x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for tileY in Swift.stride(from: y, to: y + height, by: 64) {
            let h = min(64, y + height - tileY)
            for tileX in Swift.stride(from: x, to: x + width, by: 64) {
                let w = min(64, x + width - tileX)
                var tile: [UInt32] = []
                tile.reserveCapacity(w * h)
                for row in tileY ..< tileY + h {
                    for col in tileX ..< tileX + w { tile.append(scene.pixel(at: row * scene.width + col)) }
                }
                encodeTile(tile, into: &out)
            }
        }
        return out
    }

    private func cpixel(_ pixel: UInt32, into out: inout [UInt8]) {
        out.append(contentsOf: [UInt8(pixel & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8((pixel >> 16) & 0xFF)])
    }

    private func encodeTile(_ tile: [UInt32], into out: inout [UInt8]) {
        if tile.allSatisfy({ $0 == tile[0] }) {
            out.append(1)
            cpixel(tile[0], into: &out)
            return
        }
        var runs: [(UInt32, Int)] = []
        for pixel in tile {
            if let last = runs.last, last.0 == pixel { runs[runs.count - 1].1 += 1 } else { runs.append((pixel, 1)) }
        }
        let rleSize = runs.reduce(0) { $0 + 3 + ($1.1 - 1) / 255 + 1 }
        if rleSize < tile.count * 3 {
            out.append(128)
            for (pixel, length) in runs {
                cpixel(pixel, into: &out)
                var remaining = length - 1
                while remaining >= 255 {
                    out.append(255)
                    remaining -= 255
                }
                out.append(UInt8(remaining))
            }
            return
        }
        out.append(0)
        for pixel in tile { cpixel(pixel, into: &out) }
    }
}

/// One deflate stream per connection, flushed per rectangle. Like the client's
/// ZlibStream, the `z_stream` stays at one heap address from `deflateInit_` to
/// `deflateEnd` (zlib refuses a moved stream, deflate.c deflateStateCheck), and its
/// `next_in` / `next_out` point into Swift arrays only during one `deflate` call.
final class Deflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() {
        // SAFETY: one z_stream, initialized on the next line and freed once in deinit.
        stream = unsafe UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        // SAFETY: the allocation above, not yet initialized.
        unsafe stream.initialize(to: z_stream())
        // SAFETY: deflateInit_ fills the initialized stream at its final address; it reads the
        // NUL-terminated version string Swift passes for this call only.
        _ = unsafe deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit {
        // SAFETY: the stream init set up, ended once here (a failed init leaves no state to end).
        _ = unsafe deflateEnd(stream)
        // SAFETY: the one z_stream init initialized: deinitialized and freed once, here.
        unsafe stream.deinitialize(count: 1)
        // SAFETY: as above.
        unsafe stream.deallocate()
    }

    func deflate(_ input: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        input.withUnsafeBufferPointer { source in
            // SAFETY: next_in points at `source`, valid for this closure; zlib reads at most
            // avail_in = source.count bytes and never writes through it (the mutable pointer is
            // only zlib's declared type), and the defer clears it before the closure returns.
            unsafe stream.pointee.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            // SAFETY: the live stream; a field write.
            unsafe stream.pointee.avail_in = uInt(source.count)
            // SAFETY: the live stream; no pointer into `source` outlives the closure.
            defer { unsafe stream.pointee.next_in = nil }
            while true {
                let produced = chunk.withUnsafeMutableBufferPointer { out -> Int in
                    // SAFETY: next_out points at `out`, valid for this closure; zlib writes at most
                    // avail_out = out.count bytes, and the defer clears it before the closure returns.
                    unsafe stream.pointee.next_out = out.baseAddress
                    // SAFETY: the live stream; a field write.
                    unsafe stream.pointee.avail_out = uInt(out.count)
                    // SAFETY: the live stream; no pointer into `out` outlives the closure.
                    defer { unsafe stream.pointee.next_out = nil }
                    // SAFETY: the stream is initialized and its in/out windows are set above.
                    _ = unsafe zlib.deflate(stream, Z_SYNC_FLUSH)
                    // SAFETY: the live stream; a field read.
                    return unsafe out.count - Int(stream.pointee.avail_out)
                }
                result.append(contentsOf: chunk[0 ..< produced])
                // SAFETY: the live stream; a field read.
                let outputLeft = unsafe stream.pointee.avail_out
                guard outputLeft == 0 else { break }
            }
        }
        return result
    }
}

/// The server side of VNC password authentication (same DES as the client).
struct DemoVNCAuth {
    var password: String

    func response(challenge: [UInt8]) -> [UInt8] {
        VNCPasswordResponse(password: password, challenge: challenge).bytes
    }
}

/// A small arrow cursor as a Cursor pseudo-encoding rectangle.
struct DemoCursor {
    func rectangle() -> [UInt8] {
        let w = 12, h = 18
        var colours: [UInt8] = []
        var mask: [UInt8] = []
        for row in 0 ..< h {
            var maskRow = [UInt8](repeating: 0, count: (w + 7) / 8)
            for col in 0 ..< w {
                let inside = col <= row && col < w && row < h - 4 || (row >= h - 4 && col >= 3 && col <= 6)
                let edge = col == 0 || col == row || row == h - 5 && col > 6
                let colour: UInt8 = inside && !edge ? 255 : 0
                colours.append(contentsOf: [colour, colour, colour, 0])
                if inside || edge { maskRow[col / 8] |= 0x80 >> UInt8(col % 8) }
            }
            mask.append(contentsOf: maskRow)
        }
        var bytes = DemoBytes()
        bytes.u16(0)
        bytes.u16(0)
        bytes.u16(w)
        bytes.u16(h)
        bytes.s32(RFBEncoding.cursor.rawValue)
        bytes.append(colours)
        bytes.append(mask)
        return bytes.data
    }
}
