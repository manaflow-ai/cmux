#if canImport(UIKit) && DEBUG
import Foundation
import Network
import Security

// Terminal Lab: DEBUG-only client for the terminal-lab wire protocol v1
// (cmuxterm-hq terminal-lab/PROTOCOL.md, served by termd). Ported from the
// TermLab spike app so the same snapshot/tail attach semantics can be
// dogfooded inside the real cmux iOS app against a termd on the paired Mac.
// Never compiled into release.

/// Frame types from PROTOCOL.md v1.
enum TerminalLabFrameType: UInt8 {
    case hello = 0x01
    case welcome = 0x02
    case attach = 0x03
    case snapshot = 0x04
    case output = 0x05
    case input = 0x06
    case resize = 0x07
    case resized = 0x08
    case exit = 0x09
    case ping = 0x0A
    case pong = 0x0B
    case error = 0x0C
}

enum TerminalLabWire {
    static let maxPayload = 16 * 1024 * 1024 // 16 MiB

    /// Encode one frame: u32 LE payload_len, u8 type, payload.
    static func encode(_ type: TerminalLabFrameType, payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }
}

/// Incremental frame parser. Feed arbitrary chunks; emits complete frames.
struct TerminalLabFrameDecoder {
    private var buffer = Data()

    enum DecodeError: Error {
        case oversizedPayload(UInt32)
    }

    /// Appends bytes and returns all complete frames now available.
    /// Unknown frame types are returned with rawType set and type nil.
    mutating func feed(_ data: Data) throws -> [(type: TerminalLabFrameType?, rawType: UInt8, payload: Data)] {
        buffer.append(data)
        var frames: [(TerminalLabFrameType?, UInt8, Data)] = []
        while buffer.count >= 5 {
            let len = UInt32(littleEndian: buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            })
            guard len <= TerminalLabWire.maxPayload else { throw DecodeError.oversizedPayload(len) }
            let total = 5 + Int(len)
            guard buffer.count >= total else { break }
            let rawType = buffer[buffer.startIndex + 4]
            let payload = Data(buffer[(buffer.startIndex + 5)..<(buffer.startIndex + total)])
            buffer.removeFirst(total)
            frames.append((TerminalLabFrameType(rawValue: rawType), rawType, payload))
        }
        return frames
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}

private extension Data {
    func labLEUInt64(at offset: Int) -> UInt64? {
        guard count >= offset + 8 else { return nil }
        let v = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        return UInt64(littleEndian: v)
    }

    func labLEUInt16(at offset: Int) -> UInt16? {
        guard count >= offset + 2 else { return nil }
        let v = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        return UInt16(littleEndian: v)
    }

    func labLEInt32(at offset: Int) -> Int32? {
        guard count >= offset + 4 else { return nil }
        let v = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return Int32(bitPattern: UInt32(littleEndian: v))
    }

    mutating func labAppendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

/// TCP client for the terminal-lab wire protocol v1.
///
/// State machine: idle -> connecting -> helloSent -> attaching -> streaming.
/// On any transport error, protocol error, or OUTPUT gen discontinuity the
/// connection is torn down and rebuilt (reconnect is just re-attach; the
/// protocol is idempotent). SNAPSHOT is also accepted while streaming and
/// resets client state.
final class TerminalLabClient: ObservableObject, @unchecked Sendable {
    enum ConnState: String {
        case idle, connecting, helloSent, attaching, streaming, exited
    }

    // Published UI state (main thread). Mirrors the queue-side authoritative
    // `connState`.
    @Published private(set) var state: ConnState = .idle
    @Published private(set) var sessionId: String = "-"
    @Published private(set) var gen: UInt64 = 0
    @Published private(set) var cols: UInt16 = 0
    @Published private(set) var rows: UInt16 = 0
    @Published private(set) var attachCount: Int = 0
    @Published private(set) var lastError: String?

    /// SNAPSHOT payload bytes (screen must reset, then apply). Called on main.
    var onSnapshot: ((Data) -> Void)?
    /// Contiguous OUTPUT bytes. Called on main.
    var onOutput: ((Data) -> Void)?
    /// Server confirmed a PTY size (reply to RESIZE, or another client's). Main.
    var onResized: ((UInt16, UInt16) -> Void)?

    let host: String
    let port: UInt16
    /// Shared-secret HELLO token, required by termd --token (non-loopback binds).
    let token: String?

    private let queue = DispatchQueue(label: "dev.cmux.terminal-lab.client")
    private var connState: ConnState = .idle // authoritative, queue-only
    private var conn: NWConnection?
    private var decoder = TerminalLabFrameDecoder()
    private var expectedGen: UInt64 = 0
    private var started = false
    private var reconnectDelay: TimeInterval = 0.5
    private var reconnectTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var lastPingPayload = Data()
    private var generation = 0 // connection incarnation, guards stale callbacks

    /// Desired size; replayed right after every attach so a RESIZE composed
    /// while disconnected is not lost.
    private var desiredCols: UInt16 = 0
    private var desiredRows: UInt16 = 0

    init(host: String, port: UInt16, token: String?) {
        self.host = host
        self.port = port
        self.token = (token?.isEmpty == true) ? nil : token
    }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            openConnection()
        }
    }

    func stop() {
        queue.async { [self] in
            started = false
            teardown(reason: nil, reconnect: false)
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private func openConnection() {
        generation += 1
        let myGen = generation
        decoder.reset()
        expectedGen = 0
        setState(.connecting)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fail("invalid port \(port)", reconnect: false)
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            self?.queue.async {
                guard let self, self.generation == myGen else { return }
                switch st {
                case .ready:
                    self.sendHello()
                    self.receiveLoop(c, myGen)
                case .failed(let err):
                    self.fail("connect failed: \(err)", reconnect: true)
                case .waiting(let err):
                    // Connection refused / no listener. NWConnection would sit
                    // in .waiting until a path change, which never fires for a
                    // new listener, so cancel and re-dial on our own timer.
                    self.fail("waiting: \(err); retrying", reconnect: true)
                default:
                    break
                }
            }
        }
        c.start(queue: queue)
    }

    private func teardown(reason: String?, reconnect: Bool) {
        generation += 1
        pingTimer?.cancel(); pingTimer = nil
        reconnectTimer?.cancel(); reconnectTimer = nil
        conn?.cancel(); conn = nil
        decoder.reset()
        if let reason { publish { self.lastError = reason } }
        setState(.idle)
        if reconnect && started {
            scheduleReconnect()
        }
    }

    private func fail(_ reason: String, reconnect: Bool) {
        teardown(reason: reason, reconnect: reconnect)
    }

    private func scheduleReconnect() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + reconnectDelay)
        reconnectDelay = min(reconnectDelay * 2, 5.0)
        t.setEventHandler { [weak self] in
            guard let self, self.started else { return }
            self.openConnection()
        }
        t.resume()
        reconnectTimer = t
    }

    // MARK: - Receive

    private func receiveLoop(_ c: NWConnection, _ myGen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, self.generation == myGen else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try self.decoder.feed(data) {
                            self.handleFrame(frame.type, frame.rawType, frame.payload)
                            guard self.generation == myGen else { return } // torn down mid-batch
                        }
                    } catch {
                        self.fail("framing error: \(error)", reconnect: true)
                        return
                    }
                }
                if let error {
                    self.fail("recv failed: \(error)", reconnect: true)
                    return
                }
                if isComplete {
                    self.fail("server closed connection", reconnect: true)
                    return
                }
                self.receiveLoop(c, myGen)
            }
        }
    }

    // MARK: - Frame handling (on `queue`)

    private func handleFrame(_ type: TerminalLabFrameType?, _ rawType: UInt8, _ payload: Data) {
        guard let type else {
            // Unknown type: tolerate and skip (forward compatibility).
            publish { self.lastError = String(format: "unknown frame 0x%02X", rawType) }
            return
        }
        switch type {
        case .welcome: handleWelcome(payload)
        case .snapshot: handleSnapshot(payload)
        case .output: handleOutput(payload)
        case .resized: handleResized(payload)
        case .exit: handleExit(payload)
        case .pong: handlePong(payload)
        case .error: handleServerError(payload)
        default:
            // Client->server frame types arriving at the client are a protocol error.
            fail(String(format: "unexpected frame 0x%02X from server", rawType), reconnect: true)
        }
    }

    private func sendHello() {
        setState(.helloSent)
        var hello: [String: Any] = ["proto": 1, "client": "ios", "name": "cmux-ios-lab"]
        if let token { hello["token"] = token }
        sendJSON(.hello, hello)
    }

    private func handleWelcome(_ payload: Data) {
        guard connState == .helloSent,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let proto = obj["proto"] as? Int, proto == 1,
              let sessions = obj["sessions"] as? [[String: Any]] else {
            fail("bad WELCOME payload", reconnect: true)
            return
        }
        let target = sessions.first(where: { ($0["id"] as? String) == "main" }) ?? sessions.first
        guard let target, let id = target["id"] as? String else {
            fail("WELCOME listed no sessions", reconnect: true)
            return
        }
        publish {
            self.sessionId = id
            if let c = target["cols"] as? Int { self.cols = UInt16(clamping: c) }
            if let r = target["rows"] as? Int { self.rows = UInt16(clamping: r) }
            if let g = target["gen"] as? Int { self.gen = UInt64(max(0, g)) }
        }
        setState(.attaching)
        sendJSON(.attach, ["session": id])
    }

    private func handleSnapshot(_ payload: Data) {
        // Accepted in .attaching (the one guaranteed reply) and in .streaming
        // (v2 spam coalescing sends a fresh SNAPSHOT instead of a gap).
        guard connState == .attaching || connState == .streaming else {
            fail("SNAPSHOT in state \(connState.rawValue)", reconnect: true)
            return
        }
        guard payload.count >= 13,
              let g = payload.labLEUInt64(at: 0),
              let c = payload.labLEUInt16(at: 8),
              let r = payload.labLEUInt16(at: 10) else {
            fail("short SNAPSHOT header", reconnect: true)
            return
        }
        let bytes = payload.count > 13 ? payload.subdata(in: (payload.startIndex + 13)..<payload.endIndex) : Data()
        expectedGen = g
        reconnectDelay = 0.5 // healthy attach resets backoff
        setState(.streaming)
        publish {
            self.gen = g
            self.cols = c
            self.rows = r
            self.attachCount += 1
            self.lastError = nil
            self.onSnapshot?(bytes)
        }
        // Replay desired size so a RESIZE composed while disconnected lands.
        if desiredCols > 0 && desiredRows > 0 {
            sendResizeRaw(desiredCols, desiredRows)
        }
        startPing()
    }

    private func handleOutput(_ payload: Data) {
        guard connState == .streaming else { return } // OUTPUT before SNAPSHOT: ignore
        guard let genStart = payload.labLEUInt64(at: 0) else {
            fail("short OUTPUT header", reconnect: true)
            return
        }
        let bytes = payload.count > 8 ? payload.subdata(in: (payload.startIndex + 8)..<payload.endIndex) : Data()
        guard genStart == expectedGen else {
            // Gen discontinuity: tear down and re-attach automatically.
            fail("gen gap: expected \(expectedGen), got \(genStart); re-attaching", reconnect: true)
            return
        }
        expectedGen += UInt64(bytes.count)
        let newGen = expectedGen
        publish {
            self.gen = newGen
            self.onOutput?(bytes)
        }
    }

    private func handleResized(_ payload: Data) {
        guard let c = payload.labLEUInt16(at: 0),
              let r = payload.labLEUInt16(at: 2),
              payload.labLEUInt64(at: 4) != nil else {
            fail("short RESIZED payload", reconnect: true)
            return
        }
        publish {
            self.cols = c
            self.rows = r
            self.onResized?(c, r)
        }
    }

    private func handleExit(_ payload: Data) {
        let status = payload.labLEInt32(at: 0) ?? -1
        // Session is over; log stays readable server-side. Stop reconnecting.
        pingTimer?.cancel(); pingTimer = nil
        setState(.exited)
        publish { self.lastError = "session exited (status \(status))" }
    }

    private func handlePong(_ payload: Data) {
        if payload != lastPingPayload {
            publish { self.lastError = "PONG payload mismatch" }
        }
    }

    private func handleServerError(_ payload: Data) {
        let msg: String
        if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            msg = "server error \(obj["code"] as? String ?? "?"): \(obj["msg"] as? String ?? "")"
        } else {
            msg = "server error (unparseable payload)"
        }
        fail(msg, reconnect: true)
    }

    // MARK: - Sends (public API hops to `queue`)

    /// Send raw bytes as INPUT.
    func sendInput(_ data: Data) {
        queue.async { [self] in
            guard connState == .streaming else { return }
            send(.input, data)
        }
    }

    /// Record desired size and send RESIZE if attached.
    func requestResize(cols: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard cols > 0, rows > 0 else { return }
            desiredCols = cols
            desiredRows = rows
            if connState == .streaming {
                sendResizeRaw(cols, rows)
            }
        }
    }

    private func sendResizeRaw(_ cols: UInt16, _ rows: UInt16) {
        var p = Data(capacity: 4)
        p.labAppendLE(cols)
        p.labAppendLE(rows)
        send(.resize, p)
    }

    private func startPing() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, self.connState == .streaming else { return }
            var p = Data(count: 8)
            _ = p.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
            self.lastPingPayload = p
            self.send(.ping, p)
        }
        t.resume()
        pingTimer = t
    }

    private func sendJSON(_ type: TerminalLabFrameType, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(type, data)
    }

    private func send(_ type: TerminalLabFrameType, _ payload: Data) {
        guard let conn else { return }
        conn.send(content: TerminalLabWire.encode(type, payload: payload), completion: .contentProcessed { [weak self] err in
            if let err {
                self?.queue.async { self?.fail("send failed: \(err)", reconnect: true) }
            }
        })
    }

    // MARK: - Helpers

    private func setState(_ s: ConnState) {
        connState = s
        publish { self.state = s }
    }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
#endif
