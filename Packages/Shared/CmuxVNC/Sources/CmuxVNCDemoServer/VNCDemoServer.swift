#if canImport(CoreGraphics) && canImport(CoreText) && canImport(Network)
import CmuxVNC
import CoreGraphics
import Foundation
import Network

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
        /// The server's protocol (cmux-vnc's `vnc_demo_*` ops, its DES among them); without them
        /// every viewer is dropped.
        public var rules: VNCRules

        public init(width: Int = 1280, height: Int = 800, name: String = "cmux VNC demo", password: String? = nil,
                    framesPerSecond: Int = 30, rules: VNCRules = VNCRules()) {
            self.width = width
            self.height = height
            self.name = name
            self.password = password
            self.framesPerSecond = framesPerSecond
            self.rules = rules
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
        let once = ResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.scene = DemoScene(width: self.configuration.width, height: self.configuration.height,
                                       animate: self.configuration.framesPerSecond > 0)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case let .failed(error), let .waiting(error):
                        if once.claim() { continuation.resume(throwing: error) }
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

// crash-allow: `done` is read and written only while `lock` is held.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// One viewer: its socket, pending damage and zlib stream. The protocol (the handshake, the
/// client messages, when an update goes out and its rectangles' bytes) is cmux-vnc's
/// `vnc_demo_*` ops, asked through the configuration's ``VNCRules``; the connection keeps the
/// state they hand back. Without rules (or an answer) the viewer is dropped. Confined to the queue.
// crash-allow: confined to the server queue; the connection's handlers run on it and the server calls in only from it.
final class DemoConnection: @unchecked Sendable {
    // @unchecked: confined to the server queue.
    private let connection: NWConnection
    private let scene: DemoScene
    private let configuration: VNCDemoServer.Configuration
    private let queue: DispatchQueue
    private var state = DemoRules.State()
    private var input = Data()
    /// Damage since the last update: separate rectangles, so distant changes
    /// (the status window and the moving tile) are not sent as one big union.
    private var pending: [CGRect] = []
    private var deflater: Deflater?
    var onClose: (() -> Void)?
    var onSceneChange: ((CGRect) -> Void)?

    init(connection: NWConnection, scene: DemoScene, configuration: VNCDemoServer.Configuration, queue: DispatchQueue) {
        self.connection = connection
        self.scene = scene
        self.configuration = configuration
        self.queue = queue
    }

    private var rules: DemoRules { DemoRules(rules: configuration.rules) }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed()
            default: break
            }
        }
        connection.start(queue: queue)
        send(Data("RFB 003.008\n".utf8))
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
            if let data { input.append(data) }
            process()
            if complete || error != nil { connection.cancel(); return }
            receive()
        }
    }

    private func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .idempotent)
    }

    // MARK: Client messages

    private func process() {
        guard !input.isEmpty else { return }
        let config = DemoRules.Config(width: scene.width, height: scene.height, name: configuration.name,
                                      password: configuration.password)
        guard let step = rules.receive(state, input: input, config: config) else {
            connection.cancel()
            return
        }
        state = step.connection
        input.removeFirst(min(step.consumed, input.count))
        if !step.reply.isEmpty { send(step.reply) }
        for event in step.events {
            switch event.type {
            case "fullUpdate":
                pending = [CGRect(x: 0, y: 0, width: scene.width, height: scene.height)]
            case "key":
                onSceneChange?(scene.key(event.keysym ?? 0, down: event.down ?? false, shift: event.shift ?? false))
            case "pointer":
                onSceneChange?(scene.pointer(x: event.x ?? 0, y: event.y ?? 0, leftDown: event.leftDown ?? false))
            default:
                break
            }
        }
        if let failure = step.failure {
            // Close once the reason is on the wire.
            connection.send(content: failure, completion: .contentProcessed { [connection] _ in connection.cancel() })
            return
        }
        if step.flush { flush() }
    }

    // MARK: Updates

    private func flush() {
        let damage = pending
        guard let answer = rules.flush(state, damagePending: !damage.isEmpty, damageCount: damage.count) else { return }
        state = answer.connection
        guard answer.send else { return }
        pending = []
        var bytes = answer.head
        for rect in damage {
            let x = Int(rect.minX), y = Int(rect.minY), width = Int(rect.width), height = Int(rect.height)
            guard let encoded = rules.rect(state, x: x, y: y, width: width, height: height,
                                           pixels: pixels(x: x, y: y, width: width, height: height)) else {
                connection.cancel()
                return
            }
            bytes.append(encoded.header)
            if encoded.zrle {
                let stream = deflater ?? Deflater()
                deflater = stream
                let compressed = stream.deflate(Array(encoded.payload))
                bytes.append(contentsOf: withUnsafeBytes(of: UInt32(compressed.count).bigEndian, Array.init))
                bytes.append(contentsOf: compressed)
            } else {
                bytes.append(encoded.payload)
            }
        }
        send(bytes)
    }

    /// The rectangle's BGRX pixels, row after row, little-endian (as the scene stores them).
    private func pixels(x: Int, y: Int, width: Int, height: Int) -> Data {
        let all = scene.pixels
        var data = Data(capacity: width * height * 4)
        for row in y ..< y + height {
            let start = row * scene.width + x
            data.append(UnsafeBufferPointer(rebasing: all[start ..< start + width]))
        }
        return data
    }
}

/// cmux-vnc's `vnc_demo_*` ops (cmux-tui/crates/cmux-vnc/src/demo.rs and json.rs, with their tests).
struct DemoRules {
    let rules: VNCRules

    /// One viewer's protocol state, handed back by every op (demo.rs `Connection`).
    struct State: Codable {
        var phase = "version"
        var challenge: [UInt8] = []
        var encodings: [Int32] = []
        var requested = false
        var cursorSent = false
        var buttons: UInt8 = 0
        var shift = false
    }

    struct Config: Encodable {
        var width: Int, height: Int, name: String, password: String?
    }

    struct Event: Decodable {
        var type: String
        var keysym: UInt32?, down: Bool?, shift: Bool?
        var x: Int?, y: Int?, leftDown: Bool?
    }

    struct Step: Decodable {
        var connection: State, consumed: Int, reply: Data, events: [Event], flush: Bool, failure: Data?
    }

    struct Flush: Decodable {
        var connection: State, send: Bool, head: Data
    }

    struct Rect: Decodable {
        var header: Data, zrle: Bool, payload: Data
    }

    /// Reads the whole client messages `input` holds.
    func receive(_ state: State, input: Data, config: Config) -> Step? {
        struct Request: Encodable { var connection: State, input: Data, config: Config }
        return rules.ask("vnc_demo_receive", Request(connection: state, input: input, config: config), as: Step.self)
    }

    /// Whether an update goes now, and its header (with the cursor shape first when it is due).
    func flush(_ state: State, damagePending: Bool, damageCount: Int) -> Flush? {
        struct Request: Encodable { var connection: State, damagePending: Bool, damageCount: Int }
        return rules.ask("vnc_demo_flush", Request(connection: state, damagePending: damagePending, damageCount: damageCount),
                         as: Flush.self)
    }

    /// One damaged rectangle: its header and, for ZRLE, the tiles to deflate.
    func rect(_ state: State, x: Int, y: Int, width: Int, height: Int, pixels: Data) -> Rect? {
        struct Request: Encodable { var connection: State, x: Int, y: Int, width: Int, height: Int, pixels: Data }
        return rules.ask("vnc_demo_rect", Request(connection: state, x: x, y: y, width: width, height: height, pixels: pixels),
                         as: Rect.self)
    }
}
#endif
