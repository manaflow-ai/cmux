import CmuxFuzzSupport
import CmuxNextCompat
import Foundation
@testable import CmuxNextAgentPane

/// The checks of the stream suite: one frame against its expectation, a whole stream against the model, a
/// mutated frame, a real ``AcpmuxPaneSocket`` reading a stream from a wire, and the first-line reader.
nonisolated enum AgentStreamCase {
    static let location = "AgentStreamFuzzTests"
    /// The last frame a socket run pushes: a notification marked -1.
    static let sentinel = #"{"jsonrpc":"2.0","method":"_fuzz/sentinel","mark":-1}"#

    // MARK: Relay

    /// A stream of begins, cancels and frames through one relay: every frame gets its expected outcome, the
    /// relay counts each frame it drops, and the observers end where the model ends.
    static func stream(_ rng: inout FuzzRNG) throws {
        let remote = rng.bool()
        var model = AgentStreamModel(remote: remote)
        let count = 8 + rng.below(40)
        let steps = model.steps(&rng, count: count, beginsFirst: false, duplicates: true)
        let observers = AgentStreamObservers()
        for step in steps {
            guard case .frame(let text, let expect, let value) = step else {
                try observers.apply(step)
                continue
            }
            try check(text, expect, value, on: observers, remote: remote)
        }
        try FuzzRun.check(observers.ids.droppedFrames == model.drops,
                          "the relay counted \(observers.ids.droppedFrames) dropped frames, the stream had \(model.drops)")
        try model.check(observers)
    }

    /// One frame through the relay and, when it reaches the page, the observers.
    static func check(_ text: String, _ expect: AgentStreamExpect, _ value: FuzzJSON?, on observers: AgentStreamObservers,
                      remote: Bool) throws {
        let shown = "frame \(text.prefix(400).debugDescription)"
        switch (observers.ids.toPage(text), expect) {
        case (.drop, .drop), (.close, .close):
            return
        case (.page(let fresh, let object, let method), .page):
            try FuzzRun.check(method == nil, "a notification answered \(method ?? "-"): \(shown)")
            _ = try self.object(fresh, shown)
            let original = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary
            let sent = (try? JSONSerialization.jsonObject(with: Data(fresh.utf8))) as? NSDictionary
            try FuzzRun.check(original != nil && original?.isEqual(sent) == true, "the page got \(fresh.prefix(400).debugDescription) for \(shown)")
            try observe(object, replyTo: method, value, on: observers, remote: remote, shown)
        case (.page(let fresh, let object, let method), .reply(let raw)):
            let parsed = try self.object(fresh, shown)
            try FuzzRun.check(method != nil && parsed["id"].flatMap(AcpmuxPaneMethods.rawID) == raw,
                              "reply to \(method ?? "-") got id \(String(describing: parsed["id"])), the page's is \(raw): \(shown)")
            try observe(object, replyTo: method, value, on: observers, remote: remote, shown)
        case (.complete(let object, let pageID, let subject), .complete(let raw)):
            try FuzzRun.check(pageID == raw, "reply in place for page id \(pageID), sent as \(raw): \(shown)")
            switch AgentPaneAgentReply.step(object, pageID: pageID, subject: subject, sessions: observers.sessions, canSend: false) {
            case .answer(let frame):
                let answer = try self.object(frame ?? "", shown)
                try FuzzRun.check(answer["error"] != nil && answer["id"].flatMap(AcpmuxPaneMethods.rawID) == raw,
                                  "the answer \(frame ?? "nil") is no refusal for page id \(raw): \(shown)")
            case .send:
                throw FuzzError.property("a reply in place went out with no daemon to send it: \(shown)", location: location)
            }
        case (let outcome, _):
            throw FuzzError.property("\(describe(outcome)), the contract says \(expect): \(shown)", location: location)
        }
    }

    private static func observe(_ object: [String: Any], replyTo method: String?, _ value: FuzzJSON?, on observers: AgentStreamObservers,
                                remote: Bool, _ shown: String) throws {
        observers.observe(object, replyTo: method, remote: remote)
        guard let value else { return }
        try FuzzRun.check(AcpmuxPaneSocket.pageWaits(on: object) == AgentStreamModel.pageWaits(value),
                          "a hidden pane waits \(AcpmuxPaneSocket.pageWaits(on: object)) on \(shown)")
    }

    /// `text` as one object of clean JSON (no duplicate key), or a failed property.
    static func object(_ text: String, _ shown: String) throws -> [String: Any] {
        try FuzzRun.check(AcpmuxJSONKeys.verdict(text) == .clean, "the page got \(text.prefix(400).debugDescription) for \(shown)")
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw FuzzError.property("the page got no object: \(text.prefix(400).debugDescription) for \(shown)", location: location)
        }
        return object
    }

    static func describe(_ outcome: AcpmuxRequestIds.Inbound) -> String {
        switch outcome {
        case .page(_, _, let method): "to the page (reply to \(method ?? "none"))"
        case .complete(_, let pageID, _): "completed for page id \(pageID)"
        case .drop: "dropped"
        case .close: "closed"
        }
    }

    // MARK: Mutated frames

    /// The page ids of the requests a mutated frame may answer: relay ids 1 to 9, one per method.
    static let raws = ["1", "\"p2\"", "3", "\"p4\"", "5", "\"p6\"", "7", "\"p8\"", "9"]

    /// Generated notifications and replies to relay ids 1 to 9.
    static func seeds() -> [Data] {
        var rng = FuzzRNG(seed: 0xA6E7_0179)
        var seeds = (0..<6).map { Data(AgentStreamFrames.notification(&rng, mark: $0).description.utf8) }
        for (index, method) in AgentStreamFrames.methods.enumerated() {
            let reply = AgentStreamFrames.reply(id: .int(Int64(index + 1)), method: method, &rng)
            seeds.append(Data(reply.description.utf8))
        }
        return seeds
    }

    /// Any bytes as a daemon frame, through a relay with requests 1 to 9 open: dropped (and counted),
    /// closed for two equal keys, or clean JSON to the page under a page id it sent, then the observers.
    static func mutated(_ data: Data) throws {
        let observers = AgentStreamObservers()
        observers.sessions.add("s1")
        for (raw, method) in zip(raws, AgentStreamFrames.methods) {
            let subject = method == AgentPaneAgentReply.method ? "s1" : nil
            _ = observers.ids.begin(pageID: raw, method: method, subject: subject)
            observers.sessions.sent(method: method, id: raw)
        }
        let text = String(decoding: data, as: UTF8.self)
        let shown = "frame \(text.prefix(400).debugDescription)"
        let outcome = observers.ids.toPage(text)
        let drops = observers.ids.droppedFrames
        switch outcome {
        case .page(let fresh, let object, let method):
            let parsed = try self.object(fresh, shown)
            if method != nil {
                let id = parsed["id"].flatMap(AcpmuxPaneMethods.rawID) ?? "-"
                try FuzzRun.check(raws.contains(id), "a reply under id \(id), which the page never sent: \(shown)")
            }
            observers.observe(object, replyTo: method, remote: true)
            _ = AcpmuxPaneSocket.pageWaits(on: object)
            try FuzzRun.check(drops == 0, "a frame to the page counted as dropped: \(shown)")
        case .complete(let object, let pageID, let subject):
            try FuzzRun.check(raws.contains(pageID), "a reply in place for page id \(pageID), which the page never sent: \(shown)")
            guard case .answer = AgentPaneAgentReply.step(object, pageID: pageID, subject: subject, sessions: observers.sessions,
                                                          canSend: false) else {
                throw FuzzError.property("a reply in place went out with no daemon to send it: \(shown)", location: location)
            }
        case .drop:
            try FuzzRun.check(drops == 1, "a dropped frame counted \(drops) times: \(shown)")
        case .close:
            try FuzzRun.check(AcpmuxJSONKeys.verdict(text) == .duplicate && drops == 0, "closed for no duplicate key: \(shown)")
        }
    }

    // MARK: Socket

    /// What the page must get for a frame, in order: a notification's mark, or a reply's page id.
    nonisolated enum Delivery {
        case mark(Int64)
        case id(String)
    }

    /// A remote wire the test drives: it hands each pushed frame to the socket, in order.
    nonisolated final class Wire: AcpmuxPaneWire {
        private let onFrame = Mutex<(@Sendable (String) -> Void)?>(nil)

        func open(onFrame: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Int, String) -> Void) async throws {
            self.onFrame.withLock { $0 = onFrame }
        }

        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) { completion(true) }

        func cancel(code: Int, reason: String) {}

        func push(_ text: String) { onFrame.withLock { $0 }?(text) }
    }

    /// A socket on a wire, its observers, and the wakes it gives the page.
    nonisolated struct Socket {
        let observers: AgentStreamObservers
        let wire: Wire
        let socket: AcpmuxPaneSocket
        let wakes: AsyncStream<Void>

        init() async throws {
            let (wakes, wake) = AsyncStream.makeStream(of: Void.self)
            let observers = AgentStreamObservers()
            let wire = Wire()
            self.wakes = wakes
            self.observers = observers
            self.wire = wire
            socket = AcpmuxPaneSocket(request: URLRequest(url: URL(fileURLWithPath: "/")), wire: wire, limits: AgentPaneTransport.Limits(),
                                      options: observers.options, sessions: observers.sessions, decisions: observers.decisions,
                                      ids: observers.ids, signal: { wake.yield() })
            try await socket.start(timeout: 10)
        }

        /// Pushes the stream's frames (its begins and cancels made on the spot) and what each must deliver.
        func push(_ steps: [AgentStreamStep]) throws -> [Delivery] {
            var deliveries: [Delivery] = []
            for step in steps {
                guard case .frame(let text, let expect, let value) = step else {
                    try observers.apply(step)
                    continue
                }
                switch expect {
                case .page:
                    guard case .int(let mark)? = value?["mark"] else { throw FuzzError.property("a notification without a mark", location: location) }
                    deliveries.append(.mark(mark))
                case .reply(let raw), .complete(let raw):
                    deliveries.append(.id(raw))
                case .drop, .close:
                    break
                }
                wire.push(text)
            }
            return deliveries
        }

        /// Takes what the socket gives the page at each wake until `done` holds for the frames so far or it closed.
        func take(until done: ([String]) -> Bool) async -> (frames: [String], closed: AgentPaneTransportClose?) {
            var frames: [String] = []
            var closed: AgentPaneTransportClose?
            for await _ in wakes {
                var more = true
                while more {
                    let batch = socket.take(maximumFrames: 512, maximumBytes: 4 << 20)
                    frames += batch.frames
                    closed = closed ?? batch.closed
                    more = batch.more
                }
                if closed != nil || done(frames) { break }
            }
            return (frames, closed)
        }
    }

    /// Whether `frame` (as the page got it) is ``sentinel``.
    static func isSentinel(_ frame: String) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
        return (object?["mark"] as? NSNumber)?.int64Value == -1
    }

    /// The page got exactly `deliveries`, in order, each frame clean JSON.
    static func check(_ frames: [String], _ deliveries: [Delivery]) throws {
        for (frame, delivery) in zip(frames, deliveries) {
            let object = try self.object(frame, "the socket")
            switch delivery {
            case .mark(let mark):
                try FuzzRun.check((object["mark"] as? NSNumber)?.int64Value == mark, "the page got \(frame.prefix(400)) for notification \(mark)")
            case .id(let raw):
                try FuzzRun.check(object["id"].flatMap(AcpmuxPaneMethods.rawID) == raw, "the page got \(frame.prefix(400)) for reply \(raw)")
            }
        }
    }

    /// A stream with no duplicate key, through a real socket on a wire: the socket stays open, the page gets
    /// every notification and reply in order and then the sentinel, the relay counts each frame it dropped,
    /// and the observers end where the model ends.
    static func socketStaysLive(_ rng: inout FuzzRNG) async throws {
        var model = AgentStreamModel(remote: true)
        let count = 4 + rng.below(40)
        let steps = model.steps(&rng, count: count, beginsFirst: true, duplicates: false)
        let socket = try await Socket()
        defer { socket.socket.close(code: 1000, reason: "", error: nil) }
        let deliveries = try socket.push(steps)
        socket.wire.push(sentinel)
        let (frames, closed) = await socket.take { $0.last.map(isSentinel) == true }
        try FuzzRun.check(closed == nil, "a bad frame closed the socket: \(String(describing: closed))")
        try FuzzRun.check(frames.count == deliveries.count + 1, "the page got \(frames.count) frames, the stream had \(deliveries.count) + 1")
        try check(frames, deliveries)
        try FuzzRun.check(socket.observers.ids.droppedFrames == model.drops,
                          "the relay counted \(socket.observers.ids.droppedFrames) dropped frames, the stream had \(model.drops)")
        try model.check(socket.observers)
    }

    /// A frame with two equal keys closes the socket with `duplicateKey`; the page got at most the frames
    /// before it, in order, and nothing after it.
    static func duplicateKeyCloses(_ rng: inout FuzzRNG) async throws {
        var model = AgentStreamModel(remote: true)
        let counts = (before: 1 + rng.below(20), after: 1 + rng.below(8))
        let before = model.steps(&rng, count: counts.before, beginsFirst: true, duplicates: false)
        let after = model.steps(&rng, count: counts.after, beginsFirst: false, duplicates: false)
        let socket = try await Socket()
        defer { socket.socket.close(code: 1000, reason: "", error: nil) }
        let deliveries = try socket.push(before)
        socket.wire.push(AgentStreamFrames.duplicateKeys(&rng))
        // The frames after it only: the inbound queue may still check the frames before it, whose relay ids stay as they are.
        _ = try socket.push(after.filter { if case .frame = $0 { true } else { false } })
        socket.wire.push(sentinel)
        let (frames, closed) = await socket.take { $0.last.map(isSentinel) == true }
        try FuzzRun.check(closed?.error == .duplicateKey, "the socket ended \(String(describing: closed)) after a duplicate key")
        try FuzzRun.check(frames.count <= deliveries.count, "the page got \(frames.count) frames, \(deliveries.count) came before the duplicate key")
        try check(frames, deliveries)
    }

    // MARK: First line

    /// Chunks of bytes into ``AgentPaneLineReader``: the first line up to its newline, `lineTooLong` once
    /// the bytes pass the limit with no newline, `endOfFile` at an empty chunk before either.
    static func firstLine(_ rng: inout FuzzRNG) async throws {
        let pipe = Pipe()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        var buffer = Data()
        var expected: Result<String, AgentPaneLineReader.Failure>?
        for _ in 0..<(1 + rng.below(6)) {
            var chunk: Data
            switch rng.below(6) {
            case 0: chunk = Data()
            case 1: chunk = Data(repeating: UInt8(ascii: "a"), count: rng.int(in: 1...40_000))
            default: chunk = rng.bytes(96)
            }
            if !chunk.isEmpty, rng.oneIn(3) { chunk.insert(0x0A, at: rng.below(chunk.count + 1)) }
            reader.receive(chunk)
            guard expected == nil else { continue }
            guard !chunk.isEmpty else {
                expected = .failure(.endOfFile)
                continue
            }
            buffer += chunk
            if let newline = buffer.firstIndex(of: 0x0A) {
                expected = .success(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            } else if buffer.count > AgentPaneLineReader.maximumLength {
                expected = .failure(.lineTooLong)
            }
        }
        if expected == nil {
            reader.receive(Data())
            expected = .failure(.endOfFile)
        }
        let got: Result<String, AgentPaneLineReader.Failure>
        do {
            got = .success(try await reader.firstLine())
        } catch let failure as AgentPaneLineReader.Failure {
            got = .failure(failure)
        }
        try FuzzRun.check(got == expected, "first line \(String(describing: got).prefix(200)), expected \(String(describing: expected).prefix(200))")
    }
}
