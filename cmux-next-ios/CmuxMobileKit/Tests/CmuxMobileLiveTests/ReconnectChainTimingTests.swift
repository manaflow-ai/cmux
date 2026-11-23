import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: this runs in the iOS simulator test pass.
#if os(iOS)

// What the phone does after a fresh link is adopted on foreground, until the open chat has its
// first live event (Leo, ask-48f698fc26: reopening a chat after background took ~7 s; the dial
// is measured in Rust, this is what follows it in Swift).
//
// The real coordinator, controller, pairing, acpmux hub, chat source and chat store run against
// a fake Mac whose link carries messages in round trips the test steps through (lockstep): the
// phone sends, then the Mac gets everything sent so far and its answers reach the phone at once.
// A round trip is counted, never timed, so the count is the same on a loaded runner. The
// fake Mac answers as cmux-mobile-host and acpmux do: `auth` sends its challenge when it opens
// and `{"ok":true}` for the signature; every channel opened after `auth` is held until it passes
// (host.rs accept loop, `LinkAuth::gate`); acpmux answers `initialize`, `_acpmux/watch` and
// `_acpmux/attach`, then sends one live record. The dial itself returns at once.
//
// Each run: background, foreground (`.resume` replaces the link), then round trips. Before each
// round trip ends, the test waits for what the phone must have sent by then for the chain to
// take three: the `auth` open; the signature, `initialize` and the chats' first page (riding
// behind `auth`, not after it); the attach. A phone that waits for an answer instead never sends
// it, and the wait fails, naming the send. Prints, per RTT, `CHAIN_STEP` (the round trip of each
// step, as ms at that RTT, p50/p95 of 10 runs) and `CHAIN_RTTS`, and expects at most three
// serial round trips (pairing's two and the attach).

/// The marks of one run: the round trip in which each step first happened.
// crash-allow: every mutable field is read and written only under `lock`
private final class ChainMarks: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [String: Int] = [:]
    private var link: ObjectIdentifier?
    private var currentRound = 0

    func reset() { lock.withLock { marks = [:]; link = nil; currentRound = 0 } }
    /// The round trip the run is in: 0 until the Mac's first answers reach the phone.
    var round: Int {
        get { lock.withLock { currentRound } }
        set { lock.withLock { currentRound = newValue } }
    }
    /// From now on, wire marks count only for `link` (the old link's stragglers are not this run's).
    func follow(_ link: AnyObject) { lock.withLock { self.link = ObjectIdentifier(link) } }

    func mark(_ step: String, link: AnyObject? = nil) {
        lock.withLock {
            if let link, ObjectIdentifier(link) != self.link { return }
            if marks[step] == nil { marks[step] = currentRound }
        }
    }

    var all: [String: Int] { lock.withLock { marks } }
}

/// The link's two directions. Free, a message is delivered at once (in order); held, messages
/// wait until the test ends the round trip: the Mac gets what the phone sent, then the phone gets
/// what the Mac answered.
// crash-allow: every mutable field is read and written only under `lock`
private final class Lockstep: @unchecked Sendable {
    typealias Work = @Sendable () -> Void
    private let lock = NSLock()
    private var held = false
    private var up: [Work] = []
    private var down: [Work] = []
    private let continuation: AsyncStream<Work>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Work.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task.detached(priority: .high) {
            for await work in stream { work() }
        }
    }

    func send(up isUp: Bool, _ work: @escaping Work) {
        let queued = lock.withLock { () -> Bool in
            guard held else { return false }
            if isUp { up.append(work) } else { down.append(work) }
            return true
        }
        if !queued { continuation.yield(work) }
    }

    func hold() { lock.withLock { held = true } }

    /// One round trip: the Mac gets everything the phone sent, then the phone gets the answers.
    func roundTrip() {
        for work in lock.withLock({ defer { up = [] }; return up }) { work() }
        for work in lock.withLock({ defer { down = [] }; return down }) { work() }
    }

    /// Back to free delivery, after the round trips still owed. The queues go empty and delivery
    /// goes free under one lock, so no message sent meanwhile is left behind later ones.
    func release() {
        while let owed = lock.withLock({ () -> (ups: [Work], downs: [Work])? in
            if up.isEmpty, down.isEmpty {
                held = false
                return nil
            }
            defer { up = []; down = [] }
            return (ups: up, downs: down)
        }) {
            // The Mac's answers to `ups` queue behind `downs` and go in the next pass.
            for work in owed.ups { work() }
            for work in owed.downs { work() }
        }
    }
}

/// The Mac's acpmux: chat `s1` with three finished turns. Each attach after the first finds what
/// happened while the phone was away (the last live turn's end and one more turn), and every
/// attach is followed by one live record (a new prompt, `l<n>`).
// crash-allow: the log and counters change only under `lock` (init runs before it is shared)
private final class FakeAcpmux: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var turns = 0
    private var attaches = 0

    init() {
        for _ in 0..<3 { appendTurn() }
    }

    var attachCount: Int { lock.withLock { attaches } }

    /// The ids the store shows after reattach `n` (1...): the missed turn and the live prompt.
    static func missedTurn(_ n: Int) -> String { "t\(2 + n)" }
    static func liveTurn(_ n: Int) -> String { "l\(n)" }

    private func appendTurn() {
        let n = turns
        turns += 1
        let s = log.count + 1
        log += [
            #"{"sessionId":"s1","seq":\#(s),"at":1,"dir":"mux","kind":"user_message","msg":{"text":"prompt \#(n)","promptId":"p\#(n)","turnId":"t\#(n)"}}"#,
            #"{"sessionId":"s1","seq":\#(s + 1),"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t\#(n)"}}"#,
            #"{"sessionId":"s1","seq":\#(s + 2),"at":3,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"answer \#(n)"}}}}}"#,
            #"{"sessionId":"s1","seq":\#(s + 3),"at":4,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t\#(n)"}}"#,
        ]
    }

    /// The replies to one request, in order.
    func answer(_ object: [String: Any]) -> [Data] {
        guard let method = object["method"] as? String, let rawID = object["id"] else { return [] }
        let id = "\(rawID)"
        func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
        switch method {
        case "initialize":
            return [reply(#"{"protocolVersion":1}"#)]
        case "_acpmux/watch":
            return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
        case "_acpmux/attach":
            let after = ((object["params"] as? [String: Any])?["afterSeq"] as? NSNumber)?.intValue ?? 0
            return lock.withLock { () -> [Data] in
                attaches += 1
                if after > 0 {
                    // While the phone was away: the live turn ended, and one more turn ran.
                    let s = log.count + 1
                    log.append(#"{"sessionId":"s1","seq":\#(s),"at":4,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"l\#(attaches - 2)"}}"#)
                    appendTurn()
                }
                let page = log.filter { record in
                    guard let seq = (try? JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any])?["seq"] as? Int
                    else { return false }
                    return seq > after
                }
                let first = reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"events":[\#(page.joined(separator: ","))]}"#)
                let live = attaches - 1
                let seq = log.count + 1
                let record = #"{"sessionId":"s1","seq":\#(seq),"at":5,"dir":"mux","kind":"user_message","msg":{"text":"live \#(live)","promptId":"pl\#(live)","turnId":"l\#(live)"}}"#
                log.append(record)
                return [first, Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#(record)}"#.utf8)]
            }
        case "_acpmux/events":
            return [reply(#"{"events":[],"hasMore":false}"#)]
        default:
            return [reply("{}")]
        }
    }
}

/// The Mac: its acpmux, the latency of the next link, and the run's marks.
// crash-allow: `oneWayLatency` is read and written only under `lock`; the rest is immutable
private final class FakeMac: @unchecked Sendable {
    let macID: String
    let acpmux = FakeAcpmux()
    let marks = ChainMarks()
    let lockstep = Lockstep()
    private let lock = NSLock()
    private var oneWayLatency: Duration = .milliseconds(40)

    init(macID: String) { self.macID = macID }

    var oneWay: Duration {
        get { lock.withLock { oneWayLatency } }
        set { lock.withLock { oneWayLatency = newValue } }
    }

    /// The daemon's setup answers (WorkspaceSync.prepare's batch): no workspaces.
    static func daemon(_ data: Data) -> [Data] {
        data.split(separator: 0x0A).compactMap { request -> Data? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                  let id = object["id"] as? String else { return nil }
            let line: String
            switch object["cmd"] as? String ?? "" {
            case "list-workspaces": line = #"{"id":"\#(id)","ok":true,"data":{"workspaces":[]}}"#
            case "list-agents": line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
            default: line = #"{"id":"\#(id)","ok":true,"data":{}}"#
            }
            return Data(line.utf8) + Data([0x0A])
        }
    }
}

/// The phone's end of one channel.
// crash-allow: one reader calls `receive` (the iterator), as MockChannel; the rest is immutable or a continuation
private final class ChainChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32
    let service: String
    private weak var link: ChainLink?
    private let inbox: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.AsyncIterator

    init(id: UInt32, service: String, link: ChainLink) {
        self.id = id
        self.service = service
        self.link = link
        (inbox, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        iterator = inbox.makeAsyncIterator()
    }

    func send(_ data: Data) async throws {
        guard let link else { throw LinkError(code: "closed", message: "link closed") }
        link.phoneSent(self, data)
    }

    func receive() async throws -> Data? { await iterator.next() }

    func close(code: String, reason: String) async { continuation.finish() }

    func deliver(_ data: Data) { continuation.yield(data) }
    func end() { continuation.finish() }
}

/// A link to the fake Mac. Opening a channel costs no round trip (the open frame travels with
/// the data behind it); the Mac serves a channel opened after `auth` only once `auth` passed.
// crash-allow: every mutable field is read and written only under `lock`
private final class ChainLink: MacLink, @unchecked Sendable {
    let transport: CmuxMobileTransport.TransportKind = .wireGuard
    let connectedPath: LinkPathKind? = .direct
    let states: AsyncStream<LinkState>
    private let stateContinuation: AsyncStream<LinkState>.Continuation
    private let mac: FakeMac
    private let oneWay: Duration
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var paired = false
    private var held: [@Sendable () -> Void] = []
    private var channels: [ChainChannel] = []
    /// acpmux request id -> method, to name the replies.
    private var methods: [String: String] = [:]

    init(mac: FakeMac) {
        let delay = mac.oneWay
        self.mac = mac
        oneWay = delay
        (states, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected(.wireGuard, .direct, rttMillis: rttMillis))
    }

    private var rttMillis: UInt32 { UInt32(oneWay.components.seconds * 2000 + oneWay.components.attoseconds * 2 / 1_000_000_000_000_000) }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        let channel = lock.withLock { () -> ChainChannel in
            defer { nextID += 2 }
            let channel = ChainChannel(id: nextID, service: service, link: self)
            channels.append(channel)
            return channel
        }
        mac.marks.mark("\(service)_open", link: self)
        mac.lockstep.send(up: true) { [self] in macOpened(channel) }
        return channel
    }

    /// The pong, one round trip later like every other answer: a chain that waits on the probe
    /// pays that round trip. The probe's bound is on the coordinator's test clock, which the test
    /// never moves, so the probe never times out.
    func ping() async throws -> UInt32 {
        let lockstep = mac.lockstep
        await withCheckedContinuation { (pong: CheckedContinuation<Void, Never>) in
            lockstep.send(up: true) { lockstep.send(up: false) { pong.resume() } }
        }
        return rttMillis
    }

    func probe(timeout: Duration) async throws -> UInt32? { try await ping() }

    func close() async {
        let open = lock.withLock { channels }
        for channel in open { channel.end() }
        stateContinuation.yield(.disconnected(reason: "closed"))
        stateContinuation.finish()
    }

    // MARK: Phone side

    func phoneSent(_ channel: ChainChannel, _ data: Data) {
        switch channel.service {
        case "auth":
            mac.marks.mark("auth_signature_out", link: self)
        case "acpmux":
            for object in Self.objects(data) {
                guard let method = object["method"] as? String else { continue }
                if let id = object["id"] { lock.withLock { methods["\(id)"] = method } }
                mac.marks.mark("\(Self.short(method))_out", link: self)
            }
        default:
            break
        }
        mac.lockstep.send(up: true) { [self] in macReceived(channel, data) }
    }

    /// A message reaches the phone's channel.
    private func arrived(_ channel: ChainChannel, _ data: Data) {
        channel.deliver(data)
        switch channel.service {
        case "auth":
            let ok = Self.objects(data).first?["ok"] as? Bool == true
            mac.marks.mark(ok ? "auth_ok_in" : "auth_challenge_in", link: self)
        case "acpmux":
            for object in Self.objects(data) {
                if let id = object["id"], let method = lock.withLock({ methods["\(id)"] }) {
                    mac.marks.mark("\(Self.short(method))_in", link: self)
                } else if object["method"] as? String == "_acpmux/event" {
                    mac.marks.mark("event_in", link: self)
                }
            }
        default:
            break
        }
    }

    // MARK: Mac side (runs when the phone's message arrives)

    private func toPhone(_ channel: ChainChannel, _ data: Data) {
        mac.lockstep.send(up: false) { [self] in arrived(channel, data) }
    }

    /// Runs `work` now when `auth` passed, else when it does (`LinkAuth::gate`).
    private func gated(_ work: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if paired { return true }
            held.append(work)
            return false
        }
        if now { work() }
    }

    private func macOpened(_ channel: ChainChannel) {
        switch channel.service {
        case "auth":
            toPhone(channel, Data(#"{"challenge":"c0ffee","mac":"\#(mac.macID)"}"#.utf8))
        case "version":
            gated { [self] in toPhone(channel, Data(#"{"link":2,"hostd":"chain-fake","capabilities":[]}"#.utf8)) }
        default:
            break
        }
    }

    private func macReceived(_ channel: ChainChannel, _ data: Data) {
        guard channel.service != "auth" else {
            // The signature: this phone is known, so `auth` passes at once (no Allow prompt).
            let waiting = lock.withLock { () -> [@Sendable () -> Void] in
                paired = true
                defer { held = [] }
                return held
            }
            toPhone(channel, Data(#"{"ok":true}"#.utf8))
            for work in waiting { work() }
            return
        }
        gated { [self] in
            let replies: [Data]
            switch channel.service {
            case "acpmux": replies = Self.objects(data).flatMap { mac.acpmux.answer($0) }
            case "daemon": replies = FakeMac.daemon(data)
            default: replies = []
            }
            for reply in replies { toPhone(channel, reply) }
        }
    }

    static func objects(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    static func short(_ method: String) -> String {
        String(method.split(separator: "/").last ?? Substring(method))
    }
}

// crash-allow: immutable after init
private final class ChainDialer: MacLinkDialer, @unchecked Sendable {
    let mac: FakeMac
    init(mac: FakeMac) { self.mac = mac }

    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        let link = ChainLink(mac: mac)
        mac.marks.follow(link)
        mac.marks.mark("dial", link: link)
        return link
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct ReconnectChainTimingTests {
    /// The steps, in chain order.
    static let steps = [
        "resume", "dial", "auth_open", "daemon_open", "adopted", "auth_challenge_in", "auth_signature_out", "auth_ok_in",
        "paired", "acpmux_open", "initialize_out", "initialize_in", "watch_out", "watch_in", "ready", "attach_out",
        "attach_in", "catchup_applied", "event_in", "live_applied",
    ]

    /// What the phone must have done before each round trip ends, for the chain to take three from
    /// the link's adoption: pairing's two (the challenge, the signature) with `initialize` and the
    /// chats' first page riding behind `auth`, then the attach.
    static let rounds: [[String]] = [
        ["adopted", "auth_open"],
        ["auth_signature_out", "initialize_out", "watch_out"],
        ["attach_out"],
    ]

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    /// Polls `done` on the main actor until it holds. The watchdog counts time awake and only ends a
    /// wait that would hang (the phone never sends what it waits for); it decides no outcome.
    func waitFor(_ what: String, within: Duration = .seconds(30), _ done: () -> Bool) async throws {
        var watchdog = AwakeDeadline(within)
        while !done(), watchdog.hasTimeLeft() { try await Task.sleep(for: .milliseconds(1)) } // test: polls the condition
        try #require(done(), "timed out waiting for \(what)")
    }

    @Test func reconnectChainAfterForeground() async throws {
        let userID = "user-\(UUID().uuidString)"
        let teamID = "t-chain-\(UUID().uuidString.prefix(8))"
        let macID = "mac-chain-\(UUID().uuidString.prefix(8).lowercased())"
        let pick = "cmuxMobile.live.mac.\(teamID)"
        defer { UserDefaults.standard.removeObject(forKey: pick) }
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        ServiceStub.install(host: host) { _ in nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-chain-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        snapshots.save(LiveSnapshot(
            teamID: teamID, teamName: "One", macs: [MacDevice(id: macID, name: "Studio", isOnline: true)], linkedMacID: macID,
            workspaces: [macID: .init(workspaces: [], savedAt: Date(timeIntervalSince1970: 1_000))]
        ), accountID: userID)
        snapshots.flush()
        let mac = FakeMac(macID: macID)
        let secrets = MemorySecretStore()
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        // The coordinator's clock: no heartbeat, probe bound or retry fires unless the test moves it.
        let clock = LinkTestClock()
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: ChainDialer(mac: mac),
            feedStore: FeedStore(items: []),
            keys: PhoneKeys(userID: userID, service: "test.chain.\(UUID())", store: secrets, enclave: false),
            snapshots: snapshots, secrets: secrets,
            readMarks: FeedReadMarks(url: directory.appending(path: "read.json")),
            pins: MacPins(file: nil), clock: clock
        )
        defer {
            live.stop()
            clock.stop()
        }
        // No kept transcript: the chat's history comes from the Mac only.
        live.transcriptCache = nil

        // First connection: paired, chats ready, the chat open with its live record.
        try await waitFor("the first link") { store.macConnection[macID] == .connected }
        let session = try #require(live.session(macID: macID))
        try await waitFor("the first pairing") { session.pairingState == .paired }
        try await waitFor("acpmux ready") { session.acpmux.isReady }
        let summary = AgentSessionSummary(id: "s1", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                          workspaceTitle: "w", macName: "Studio")
        let source = session.acpmux.source(sessionID: "s1", summary: summary)
        let chat = AgentChatStore(source: source)
        try await waitFor("the chat's first live record") { chat.turns.contains { $0.id == "l0" } }

        // Adoption: the controller hands the coordinator a new link.
        let marks = mac.marks
        let adopted = session.link.onLink
        session.link.onLink = { link in
            if let link { marks.mark("adopted", link: link as AnyObject) }
            adopted?(link)
        }

        // The lines also go in an attachment: the simulator run keeps attachments, not stdout.
        var report: [String] = []
        func emit(_ line: String) {
            print(line)
            report.append(line)
        }
        var reattach = 0
        for rttMillis in [80] {
            mac.oneWay = .milliseconds(rttMillis / 2)
            var values: [String: [Double]] = [:]
            var serials: [Int] = []
            for _ in 0..<10 {
                reattach += 1
                let missed = FakeAcpmux.missedTurn(reattach)
                let liveTurn = FakeAcpmux.liveTurn(reattach)
                marks.reset()
                mac.lockstep.hold()
                live.background()
                marks.mark("resume")
                live.foreground()
                // Main-actor marks: each counts once its old state was seen gone.
                var sawUnpaired = false
                var sawNotReady = false
                func observe() -> Bool {
                    if session.pairingState != .paired { sawUnpaired = true } else if sawUnpaired { marks.mark("paired") }
                    if !session.acpmux.isReady { sawNotReady = true } else if sawNotReady { marks.mark("ready") }
                    if chat.turns.contains(where: { $0.id == missed }) { marks.mark("catchup_applied") }
                    if chat.turns.contains(where: { $0.id == liveTurn }) { marks.mark("live_applied") }
                    return marks.all["live_applied"] != nil
                }
                for (index, sends) in Self.rounds.enumerated() {
                    try await waitFor("round trip \(index + 1): the phone to send \(sends) before the Mac's answers of round trip \(index) (marks: \(marks.all))") {
                        _ = observe()
                        let seen = marks.all
                        return sends.allSatisfy { seen[$0] != nil }
                    }
                    marks.round = index + 1
                    mac.lockstep.roundTrip()
                }
                try await waitFor("the chat's live record \(liveTurn) (marks: \(marks.all))") { observe() }
                mac.lockstep.release()
                let seen = marks.all
                let base = try #require(seen["adopted"], "the new link was never adopted")
                for (step, round) in seen { values[step, default: []].append(Double((round - base) * rttMillis)) }
                serials.append(try #require(seen["attach_in"], "the attach never came back") - base)
            }
            for step in Self.steps {
                guard let samples = values[step], !samples.isEmpty else {
                    emit(#"CHAIN_STEP {"rtt_ms":\#(rttMillis),"step":"\#(step)","n":0}"#)
                    continue
                }
                emit(#"CHAIN_STEP {"rtt_ms":\#(rttMillis),"step":"\#(step)","n":\#(samples.count),"p50":\#(Self.fmt(Self.percentile(samples, 0.5))),"p95":\#(Self.fmt(Self.percentile(samples, 0.95)))}"#)
            }
            let attach = Self.percentile(values["attach_in"] ?? [0], 0.5)
            let liveApplied = Self.percentile(values["live_applied"] ?? [0], 0.5)
            let serial = serials.max() ?? 0
            emit(#"CHAIN_RTTS {"rtt_ms":\#(rttMillis),"serial_round_trips":\#(serial),"attach_in_p50":\#(Self.fmt(attach)),"live_applied_p50":\#(Self.fmt(liveApplied))}"#)
            // Pairing's two round trips, then the attach: `initialize` and the first page of
            // chats ride behind `auth`, not after it (ask-48f698fc26; five before).
            Attachment.record(report.joined(separator: "\n"), named: "reconnect-chain.txt")
            #expect(serial <= 3, "the chat's attach came back \(serial) round trips after the link")
        }
        // One attach per run (and the first open's): no retry hid in the numbers.
        #expect(mac.acpmux.attachCount == reattach + 1)
    }
}
#endif
