import CMUXMobileCore
import CmuxFuzzSupport
import CmuxNextDaemon
@testable import CmuxNextMobile
import Foundation

/// A daemon with nothing in it: every phone request is answered from an empty tree, and no terminal attaches.
nonisolated struct HostFuzzBackend: MobileCompatBackend {
    func tree() async throws -> DaemonTree { DaemonTree() }
    func treeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
    func createWorkspace(name: String?) async throws -> WorkspaceKey { "11111111-2222-3333-4444-555555555555" }
    func renameWorkspace(_ key: WorkspaceKey, to name: String) async throws {}
    func closeWorkspace(_ key: WorkspaceKey) async throws {}
    func createTerminal(in key: WorkspaceKey, cwd: String?) async throws -> TerminalID? { nil }
    func send(_ surface: SurfaceID, bytes: Data, paste: Bool) async throws {}
    func renameTab(_ surface: SurfaceID, to name: String) async throws {}
    func closeTerminal(_ terminal: TerminalID) async throws {}
    func attach(_ tab: TabSnapshot, generation: DaemonGeneration?, size: CellSize) async throws
        -> any MobileCompatTerminalChannel {
        throw MobileRPCError.notFound("no terminal")
    }

    static let host = MobileCompatHostInfo(macDeviceID: "mac-1", instanceTag: "fuzz", bundleIdentifier: "com.cmuxterm.app.next",
                                           displayName: "Mac", appVersion: "0", appBuild: "0", daemonLaneAvailable: false)

    /// One phone's session over this backend, as `MobileIrxHost` makes it.
    static func session() -> MobileCompatSession {
        MobileCompatSession(backend: HostFuzzBackend(), host: host, emit: { _ in })
    }
}

/// One shipped-iOS request a phone sends, and the answer its contract names against ``HostFuzzBackend``.
nonisolated struct HostPhoneRequest {
    nonisolated enum Kind: CaseIterable {
        case status, methods, probe, list, subscribe, unknown, badWorkspace
    }

    var payload: Data
    var id: JSONValue
    /// The answer's `ok`, and the error code a failure carries.
    var ok: Bool
    var code: String?

    init(_ rng: inout FuzzRNG, kind forced: Kind? = nil) throws {
        let number = rng.int(in: -1_000_000...1_000_000), text = "r" + FuzzJSON.randomString(&rng)
        let numeric = rng.bool()
        id = numeric ? .number(Double(number)) : .string(text)
        var fields: [String: FuzzJSON] = ["id": numeric ? .int(Int64(number)) : .string(text)]
        var params: [String: FuzzJSON] = [:]
        ok = true
        let drawn = rng.element(of: Kind.allCases) ?? .status
        switch forced ?? drawn {
        case .status:
            fields["method"] = .string("mobile.host.status")
        case .methods:
            fields["method"] = .string("mobile.rpc.methods")
        case .probe:
            fields["method"] = .string("mobile.events.probe")
            params["stream_id"] = .string(FuzzJSON.randomString(&rng))
        case .list:
            fields["method"] = .string(rng.bool() ? "workspace.list" : "mobile.workspace.list")
        case .subscribe:
            fields["method"] = .string("mobile.events.subscribe")
            params["topics"] = .array([.string("workspace.updated"), FuzzJSON.random(&rng)])
        case .unknown:
            // No served method starts with "fuzz.".
            fields["method"] = .string("fuzz." + FuzzJSON.randomString(&rng))
            ok = false
            code = "method_not_found"
        case .badWorkspace:
            // A UUID never starts with "x".
            fields["method"] = .string("workspace.close")
            params["workspace_id"] = .string("x" + FuzzJSON.randomString(&rng))
            ok = false
            code = "invalid_params"
        }
        if !params.isEmpty || rng.bool() { fields["params"] = .object(params) }
        if rng.oneIn(4) { fields["auth"] = FuzzJSON.random(&rng) }
        payload = try FuzzJSON.object(fields).data()
    }

    /// `answer` is this request's: its id, and the `ok` and error code the contract names.
    func check(_ answer: HostPhoneAnswer) throws {
        try FuzzRun.check(answer.id == id && answer.ok == ok && answer.code == code,
                          "\(String(decoding: payload, as: UTF8.self)) got \(answer), not id \(id) ok \(ok) \(code ?? "")")
    }
}

/// One answer frame read back: a success with a result, or a failure with a code and a message.
nonisolated struct HostPhoneAnswer: CustomStringConvertible {
    var id: JSONValue
    var ok: Bool
    var code: String?

    /// Reads one answer payload; a payload that is not a well-formed answer fails the property.
    init(_ payload: Data) throws {
        let text = String(decoding: payload, as: UTF8.self)
        guard case let .object(object)? = try? JSONDecoder().decode(JSONValue.self, from: payload),
              case let .bool(ok)? = object["ok"], let id = object["id"] else {
            throw FuzzError.property("the answer \(text) is not {id, ok, ...}", location: "HostPhoneAnswer")
        }
        self.id = id
        self.ok = ok
        if ok {
            try FuzzRun.check(object["result"] != nil && object["error"] == nil, "the success \(text) has no result")
        } else {
            guard case let .object(error)? = object["error"], case let .string(code)? = error["code"],
                  case .string? = error["message"] else {
                throw FuzzError.property("the failure \(text) has no code and message", location: "HostPhoneAnswer")
            }
            self.code = code
        }
    }

    /// Every answer frame in `bytes`, which must hold whole frames only.
    static func all(in bytes: Data) throws -> [HostPhoneAnswer] {
        var buffer = bytes
        var payloads: [Data] = []
        var frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        while !frames.isEmpty {
            payloads += frames
            frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        }
        try FuzzRun.check(buffer.isEmpty, "\(buffer.count) bytes after the last whole answer frame")
        return try payloads.map(HostPhoneAnswer.init)
    }

    var description: String { "{id \(id), ok \(ok), code \(code ?? "-")}" }
}

/// Any bytes as one request frame, straight to a phone's session: one well-formed answer, never a trap.
nonisolated enum HostSessionFrame {
    static let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + HostRPCSample.tokens, maximumCount: 8_192)

    static func check(_ frame: Data, expected: HostPhoneRequest? = nil) async throws {
        let session = HostFuzzBackend.session()
        let answer = await session.handle(frame: frame)
        await session.close()
        let read = try HostPhoneAnswer(answer)
        try expected?.check(read)
    }
}

/// Two phones' control streams served at once, as `MobileIrxConnectionServer` serves each admitted phone
/// (``MobileControlStream``): a healthy phone that sends only good requests, and a fuzzed phone that sends
/// good and mutated requests, then maybe a frame header past the codec's limit or a cut-off frame, all
/// split at random read boundaries. The fuzzed phone's stream runs from start to end while the healthy
/// phone's is paused half way.
nonisolated struct HostPhoneStreamsCase {
    nonisolated enum Item {
        case request(HostPhoneRequest)
        /// A mutated request payload in a whole frame: any well-formed answer.
        case mutated(Data)

        var payload: Data {
            switch self {
            case let .request(request): request.payload
            case let .mutated(payload): payload
            }
        }
    }

    nonisolated enum Ending {
        /// The phone closes the stream after its last frame.
        case clean
        /// A header past the frame limit, then frames that must never be answered: the stream ends with
        /// `frameTooLarge` and the phone's session closes.
        case oversized
        /// A frame cut off by the end of the stream: never answered; the stream ends as the phone closed it.
        case truncated
    }

    var healthyBefore: [HostPhoneRequest]
    var healthyAfter: [HostPhoneRequest]
    var healthyChunks: (before: [Data], after: [Data])
    var fuzzed: [Item]
    var ending: Ending
    var fuzzedChunks: [Data]

    init(_ rng: inout FuzzRNG) throws {
        healthyBefore = [try HostPhoneRequest(&rng, kind: .subscribe)]
        for _ in 0..<rng.below(4) { healthyBefore.append(try HostPhoneRequest(&rng)) }
        healthyAfter = try (0..<(1 + rng.below(4))).map { _ in try HostPhoneRequest(&rng) }
        let before = Self.chunks(try Self.frames(healthyBefore.map(\.payload)), &rng)
        let after = Self.chunks(try Self.frames(healthyAfter.map(\.payload)), &rng)
        healthyChunks = (before: before, after: after)

        // The fuzzed phone subscribes first, so its session has a stream to lose when it closes.
        fuzzed = [.request(try HostPhoneRequest(&rng, kind: .subscribe))]
        for _ in 0..<rng.below(10) {
            let request = try HostPhoneRequest(&rng)
            if rng.bool() {
                fuzzed.append(.request(request))
            } else {
                fuzzed.append(.mutated(HostSessionFrame.mutator.mutate(request.payload, using: &rng)))
            }
        }
        let whole = try Self.frames(fuzzed.map(\.payload))
        var tail = Data()
        switch rng.below(3) {
        case 0:
            ending = .clean
        case 1:
            ending = .oversized
            let limit = UInt32(MobileSyncFrameCodec.defaultMaximumFrameByteCount)
            let length = limit + 1 + UInt32(rng.below(1 << 30))
            tail.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })
            tail.append(rng.bytes(64))
            tail.append(try Self.frames([try HostPhoneRequest(&rng).payload]))
        default:
            ending = .truncated
            let payload = try HostPhoneRequest(&rng).payload
            let length = UInt32(payload.count + 1 + rng.below(100))
            tail.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })
            tail.append(payload)
        }
        // The bad tail starts a read of its own. `MobileSyncFrameCodec.decodeFrames` throws away the whole
        // frames it decoded in the same read as an oversized header, so a phone loses those answers too.
        let wholeChunks = Self.chunks(whole, &rng)
        fuzzedChunks = wholeChunks + Self.chunks(tail, &rng)
    }

    func check() async throws {
        let reached = HostFuzzGate(), fuzzedEnded = HostFuzzGate()
        let healthyTransport = HostPhoneTransport(healthyChunks.before + healthyChunks.after,
                                                  pause: (at: healthyChunks.before.count, reached: reached, resume: fuzzedEnded))
        let fuzzedTransport = HostPhoneTransport(fuzzedChunks)
        let healthySession = HostFuzzBackend.session(), fuzzedSession = HostFuzzBackend.session()

        async let healthyEnd = MobileControlStream(transport: healthyTransport, session: healthySession).run()
        await reached.wait()
        let fuzzedEnd = await MobileControlStream(transport: fuzzedTransport, session: fuzzedSession).run()
        let fuzzedSent = await fuzzedTransport.sent
        let fuzzedClosed = await fuzzedSession.treeWatch == nil
        let healthyStillSubscribed = await healthySession.treeWatch != nil
        let healthySentBefore = await healthyTransport.sent
        // Every check waits until the healthy stream is resumed and done, so a failure never leaves it paused.
        await fuzzedEnded.open()
        let healthyError = await healthyEnd
        let healthySent = await healthyTransport.sent

        switch ending {
        case .oversized:
            let framing = fuzzedEnd.map { $0 is MobileSyncFrameCodecError } ?? false
            try FuzzRun.check(framing, "an oversized frame ended the stream with \(String(describing: fuzzedEnd))")
        case .clean, .truncated:
            try FuzzRun.check(fuzzedEnd == nil, "the fuzzed phone's stream ended with \(String(describing: fuzzedEnd))")
        }
        let fuzzedAnswers = try HostPhoneAnswer.all(in: fuzzedSent)
        try FuzzRun.check(fuzzedAnswers.count == fuzzed.count, "\(fuzzedAnswers.count) answers to \(fuzzed.count) whole frames")
        for (item, answer) in zip(fuzzed, fuzzedAnswers) {
            if case let .request(request) = item { try request.check(answer) }
        }
        try FuzzRun.check(fuzzedClosed, "the fuzzed phone's session kept its event stream after its connection ended")

        try FuzzRun.check(healthyStillSubscribed, "the healthy phone lost its event stream when the other phone's connection ended")
        let answeredBefore = try HostPhoneAnswer.all(in: healthySentBefore)
        try FuzzRun.check(answeredBefore.count == healthyBefore.count, "the healthy phone had \(answeredBefore.count) answers, not \(healthyBefore.count)")
        try FuzzRun.check(healthyError == nil, "the healthy phone's stream ended with \(String(describing: healthyError))")
        let healthy = healthyBefore + healthyAfter
        let answers = try HostPhoneAnswer.all(in: healthySent)
        try FuzzRun.check(answers.count == healthy.count, "the healthy phone got \(answers.count) answers to \(healthy.count) requests")
        for (request, answer) in zip(healthy, answers) { try request.check(answer) }
    }

    /// `payloads` as consecutive frames.
    static func frames(_ payloads: [Data]) throws -> Data {
        try payloads.reduce(into: Data()) { bytes, payload in bytes.append(try MobileSyncFrameCodec.encodeFrame(payload)) }
    }

    /// `bytes` cut into reads of 1 to 512 bytes, often small ones, so frames and headers split across reads.
    static func chunks(_ bytes: Data, _ rng: inout FuzzRNG) -> [Data] {
        var chunks: [Data] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let size = 1 + rng.below(rng.oneIn(3) ? 8 : 512)
            let end = bytes.index(start, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex
            chunks.append(Data(bytes[start..<end]))
            start = end
        }
        return chunks
    }
}

/// A phone's control stream: hands out its reads, then the end of the stream, and keeps what the host sent.
/// With `pause`, the read at that index first says it was reached and waits to be resumed.
actor HostPhoneTransport: CmxByteTransport {
    private let chunks: [Data]
    private let pause: (at: Int, reached: HostFuzzGate, resume: HostFuzzGate)?
    private var next = 0
    private(set) var sent = Data()

    init(_ chunks: [Data], pause: (at: Int, reached: HostFuzzGate, resume: HostFuzzGate)? = nil) {
        self.chunks = chunks
        self.pause = pause
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if let pause, next == pause.at {
            await pause.reached.open()
            await pause.resume.wait()
        }
        guard next < chunks.count else { return nil }
        defer { next += 1 }
        return chunks[next]
    }

    func send(_ data: Data) async throws {
        sent.append(data)
    }

    func close() async {}
}

/// Opens once; every wait before then resumes when it opens, every wait after returns at once.
actor HostFuzzGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }
}
