import Foundation

// A WebRTC viewer's session (the iPhone's Screen Sharing viewer) served by another process: the
// Screen Sharing helper's `__webrtc-host` (cmux-tui/crates/cmux-rd-host src/webrtc_host.rs), which
// runs `cmux-screen-sharing-webrtc` (Sources/cmux-screen-sharing-webrtc) as its child, so the
// capture and the input it posts are the helper's, under the helper's Screen Recording and
// Accessibility grants, never the app's. The app keeps the session's signaling and relays it in
// JSON lines over the child's stdin and stdout (`ScreenRelayLine`); `ScreenRelayRunner` is the
// child's end. The app also sends the windows the capture leaves out (SECURITY: the join consent
// card and the act-as-me card only the person at this Mac may see), first with the setup, before
// any capture can start, and again on every change.

/// One signal as a relay line carries it.
public struct ScreenRelaySignal: Codable, Sendable, Equatable {
    /// `hello`, `peer-joined`, `peer-left`, `offer`, `answer`, `candidate`, `bye`, `path`.
    public var type: String
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int32?
    /// `hello`: the other side is connected too.
    public var peer: Bool?
    /// `path`: the media goes through a TURN relay.
    public var relay: Bool?

    enum CodingKeys: String, CodingKey {
        case type, sdp, candidate, peer, relay
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
    }

    public init(_ signal: ScreenSignal) {
        switch signal {
        case let .hello(peerPresent): self.init(type: "hello", peer: peerPresent)
        case .peerJoined: self.init(type: "peer-joined")
        case .peerLeft: self.init(type: "peer-left")
        case let .offer(sdp): self.init(type: "offer", sdp: sdp)
        case let .answer(sdp): self.init(type: "answer", sdp: sdp)
        case let .candidate(candidate):
            self.init(type: "candidate", candidate: candidate.candidate, sdpMid: candidate.sdpMid,
                      sdpMLineIndex: candidate.sdpMLineIndex)
        case .bye: self.init(type: "bye")
        case let .path(relay): self.init(type: "path", relay: relay)
        }
    }

    init(type: String, sdp: String? = nil, candidate: String? = nil, sdpMid: String? = nil,
         sdpMLineIndex: Int32? = nil, peer: Bool? = nil, relay: Bool? = nil) {
        self.type = type
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.peer = peer
        self.relay = relay
    }

    /// The signal; nil for a type this side does not know (a newer peer's) or one missing its field.
    public var signal: ScreenSignal? {
        switch type {
        case "hello": .hello(peerPresent: peer == true)
        case "peer-joined": .peerJoined
        case "peer-left": .peerLeft
        case "offer": sdp.map(ScreenSignal.offer)
        case "answer": sdp.map(ScreenSignal.answer)
        case "candidate":
            candidate.map { .candidate(ScreenICECandidate(candidate: $0, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)) }
        case "bye": .bye
        case "path": relay.map { ScreenSignal.path(relay: $0) }
        default: nil
        }
    }
}

/// The first line the app sends: what the child's `ScreenStreamHost` needs before the viewer's offer.
public struct ScreenRelaySetup: Codable, Sendable, Equatable {
    /// The name the viewer shows for this Mac.
    public var name: String
    /// A `view` session: the viewer's input never reaches the backend.
    public var viewOnly: Bool
    /// The session's signaling ``ScreenSignaling/endsSessionOnClose``.
    public var endsSessionOnClose: Bool
    /// The session's ICE servers (STUN, TURN relays), read by the app before the child starts.
    public var iceServers: [ICEServerConfig]
    /// SECURITY: the window ids (CGWindowID) the capture leaves out from its first frame.
    public var excludeWindows: [UInt32]

    enum CodingKeys: String, CodingKey {
        case name
        case viewOnly = "view_only"
        case endsSessionOnClose = "ends_session_on_close"
        case iceServers = "ice_servers"
        case excludeWindows = "exclude_windows"
    }

    public init(name: String, viewOnly: Bool, endsSessionOnClose: Bool, iceServers: [ICEServerConfig], excludeWindows: [UInt32]) {
        self.name = name
        self.viewOnly = viewOnly
        self.endsSessionOnClose = endsSessionOnClose
        self.iceServers = iceServers
        self.excludeWindows = excludeWindows
    }
}

/// One JSON line between the app and the relay child. Each line sets one field.
///
/// App to child: `setup` (first, once), `signal` (from the viewer), `exclude_windows` (the whole
/// list, on every change), `signals_end` (the session's signaling ended), `stop` (end now).
/// Child to app: `signal` (to the viewer), `event` (`connected`, `ended`, `failed` with `message`),
/// `close` (close the session's signaling), `served` (the host's serve returned; `error` if it threw).
public struct ScreenRelayLine: Codable, Sendable, Equatable {
    public var setup: ScreenRelaySetup?
    public var signal: ScreenRelaySignal?
    public var excludeWindows: [UInt32]?
    public var signalsEnd: Bool?
    public var stop: Bool?
    public var event: String?
    public var message: String?
    public var close: Bool?
    public var served: Bool?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case setup, signal, stop, event, message, close, served, error
        case excludeWindows = "exclude_windows"
        case signalsEnd = "signals_end"
    }

    public init(setup: ScreenRelaySetup? = nil, signal: ScreenSignal? = nil, excludeWindows: [UInt32]? = nil,
                signalsEnd: Bool? = nil, stop: Bool? = nil, event: String? = nil, message: String? = nil,
                close: Bool? = nil, served: Bool? = nil, error: String? = nil) {
        self.setup = setup
        self.signal = signal.map(ScreenRelaySignal.init)
        self.excludeWindows = excludeWindows
        self.signalsEnd = signalsEnd
        self.stop = stop
        self.event = event
        self.message = message
        self.close = close
        self.served = served
        self.error = error
    }

    public static let connected = "connected"
    public static let ended = "ended"
    public static let failed = "failed"

    /// The line's JSON and its newline.
    public var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// Splits a byte stream into ``ScreenRelayLine``s. A line that is not JSON, or one longer than
/// ``limit`` without a newline (a broken peer), is dropped, never buffered without end.
public struct ScreenRelayLineBuffer: Sendable {
    /// An SDP offer with every candidate is a few kilobytes; 1 MiB is far past any real line.
    public static let limit = 1 << 20
    private var pending = Data()

    public init() {}

    public mutating func push(_ data: Data) -> [ScreenRelayLine] {
        pending.append(data)
        var lines: [ScreenRelayLine] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex ..< newline]
            pending.removeSubrange(pending.startIndex ... newline)
            if !line.isEmpty, let decoded = try? JSONDecoder().decode(ScreenRelayLine.self, from: Data(line)) {
                lines.append(decoded)
            }
        }
        if pending.count > Self.limit { pending.removeAll() }
        return lines
    }
}

/// The windows the relay child's capture leaves out, as the app last sent them; ``onChange`` runs
/// on every new list (the running capture's filter follows at once).
// crash-allow: both fields are read and written only under `lock`.
public final class ScreenRelayExclusions: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UInt32>
    private var changed: (@Sendable () -> Void)?

    public init(_ ids: [UInt32]) {
        self.ids = Set(ids)
    }

    public var windowIDs: Set<UInt32> { lock.withLock { ids } }

    /// Replaces the observer (one capture at a time).
    public func onChange(_ changed: @escaping @Sendable () -> Void) {
        lock.withLock { self.changed = changed }
    }

    func set(_ new: [UInt32]) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            let next = Set(new)
            guard next != ids else { return nil }
            ids = next
            return self.changed
        }
        changed?()
    }
}

/// What ``ScreenRelayRunner`` serves: `ScreenStreamHost` (tests pass their own).
public protocol ScreenRelayServedHost: AnyObject, Sendable {
    var onEvent: (@Sendable (ScreenStreamHost.Event) -> Void)? { get set }
    func serve(_ signaling: any ScreenSignaling) async throws
    func disconnectViewer()
}

extension ScreenStreamHost: ScreenRelayServedHost {}

/// The relay child's signaling: signals from the app's lines, sends and closes as lines back.
// crash-allow: `closed` and `continuation` are read and written only under `lock`.
final class ScreenRelaySignaling: ScreenSignaling, @unchecked Sendable {
    private let setup: ScreenRelaySetup
    private let write: @Sendable (ScreenRelayLine) -> Void
    private let lock = NSLock()
    private var closed = false
    private let stream: AsyncThrowingStream<ScreenSignal, any Error>
    private let continuation: AsyncThrowingStream<ScreenSignal, any Error>.Continuation

    init(setup: ScreenRelaySetup, write: @escaping @Sendable (ScreenRelayLine) -> Void) {
        self.setup = setup
        self.write = write
        (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self,
                                                               bufferingPolicy: .bufferingOldest(512))
    }

    func deliver(_ signal: ScreenSignal) { continuation.yield(signal) }
    func finish() { continuation.finish() }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }
    func send(_ signal: ScreenSignal) async throws { write(ScreenRelayLine(signal: signal)) }
    func iceServers() async throws -> [ICEServerConfig] { setup.iceServers }
    var endsSessionOnClose: Bool { setup.endsSessionOnClose }

    func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if first { write(ScreenRelayLine(close: true)) }
    }
}

/// The relay child: reads the app's lines from `input`, serves the session with the host
/// `makeHost` builds from the setup, and writes the host's signals and events to `output`.
/// ``run()`` returns the exit code: on `stop`, at the end of `input` (the app ended or stopped), or
/// once the host's serve returned and no viewer is connected.
public final class ScreenRelayRunner: Sendable {
    public typealias MakeHost = @Sendable (ScreenRelaySetup, ScreenRelayExclusions) -> any ScreenRelayServedHost

    private enum Step: Sendable {
        case line(ScreenRelayLine)
        case inputEnded
        case event(ScreenStreamHost.Event)
        case served
    }

    private let input: AsyncStream<Data>
    private let write: @Sendable (Data) -> Void
    private let makeHost: MakeHost
    private let log: @Sendable (String) -> Void

    /// `input`: the app's bytes, finished at its end of file. `write`: one encoded line out.
    public init(input: AsyncStream<Data>, write: @escaping @Sendable (Data) -> Void,
                log: @escaping @Sendable (String) -> Void, makeHost: @escaping MakeHost) {
        self.input = input
        self.write = write
        self.log = log
        self.makeHost = makeHost
    }

    /// A runner on this process's stdin and stdout (the relay child): lines out one at a time.
    public static func standardIO(log: @escaping @Sendable (String) -> Void, makeHost: @escaping MakeHost) -> ScreenRelayRunner {
        let output = ScreenRelayOutput(.standardOutput)
        return ScreenRelayRunner(input: chunks(of: .standardInput), write: { output.write($0) }, log: log, makeHost: makeHost)
    }

    /// Reads `handle` until its end of file, as ``init(input:write:log:makeHost:)``'s input.
    public static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            // A thread of its own: a blocking read never holds a cooperative thread.
            let reader = Thread {
                // A failed read ends the input like its end of file (`read(upToCount:)` throws, never raises).
                while let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    continuation.yield(data)
                }
                continuation.finish()
            }
            reader.name = "cmux.screen-relay.stdin"
            reader.start()
        }
    }

    public func run() async -> Int32 {
        let (steps, sink) = AsyncStream.makeStream(of: Step.self, bufferingPolicy: .bufferingOldest(1024))
        let input = input
        // task-owner: the reader of the app's lines; ends with the input (the app's end of file)
        let reader = Task {
            var buffer = ScreenRelayLineBuffer()
            for await chunk in input {
                for line in buffer.push(chunk) { sink.yield(.line(line)) }
            }
            sink.yield(.inputEnded)
        }
        defer { reader.cancel() }
        let write = write
        let send: @Sendable (ScreenRelayLine) -> Void = { write($0.encoded) }

        var host: (any ScreenRelayServedHost)?
        var signaling: ScreenRelaySignaling?
        var exclusions: ScreenRelayExclusions?
        var serve: Task<Void, Never>?
        var served = false
        var connected = false
        defer { serve?.cancel() }

        for await step in steps {
            switch step {
            case let .line(line):
                if let setup = line.setup {
                    guard host == nil else { continue }
                    let excluded = ScreenRelayExclusions(setup.excludeWindows)
                    let relay = ScreenRelaySignaling(setup: setup, write: send)
                    let made = makeHost(setup, excluded)
                    made.onEvent = { event in sink.yield(.event(event)) }
                    host = made
                    signaling = relay
                    exclusions = excluded
                    log("serving a WebRTC viewer for the app")
                    // task-owner: the session's serve; reports back through `steps`, cancelled when run returns
                    serve = Task {
                        do {
                            try await made.serve(relay)
                            send(ScreenRelayLine(served: true))
                        } catch {
                            send(ScreenRelayLine(served: true, error: String(describing: error)))
                        }
                        sink.yield(.served)
                    }
                    continue
                }
                guard host != nil else {
                    log("a line before the setup; stopping")
                    return 2
                }
                if line.stop == true {
                    host?.disconnectViewer()
                    return 0
                }
                if let signal = line.signal?.signal { signaling?.deliver(signal) }
                if let ids = line.excludeWindows { exclusions?.set(ids) }
                if line.signalsEnd == true { signaling?.finish() }
            case .inputEnded:
                host?.disconnectViewer()
                return 0
            case let .event(event):
                switch event {
                case .viewerConnected:
                    connected = true
                    send(ScreenRelayLine(event: ScreenRelayLine.connected))
                case .viewerEnded:
                    connected = false
                    send(ScreenRelayLine(event: ScreenRelayLine.ended))
                    if served { return 0 }
                case let .sourceFailed(message):
                    send(ScreenRelayLine(event: ScreenRelayLine.failed, message: message))
                case .waiting, .roomLost: break
                }
            case .served:
                served = true
                if !connected { return 0 }
            }
        }
        return 0
    }
}

/// One handle's writes, one line at a time (the serve task and the host's callbacks write from
/// several threads). A write after the reader went fails quietly: the input's end stops the child.
// crash-allow: the handle is written only under `lock`.
final class ScreenRelayOutput: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) {
        lock.withLock { try? handle.write(contentsOf: data) }
    }
}
