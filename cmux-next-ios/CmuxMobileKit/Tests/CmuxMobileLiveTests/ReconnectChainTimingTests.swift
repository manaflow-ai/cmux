import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileNotifications
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
    private var freeLatency: Duration?
    private let continuation: AsyncStream<(due: ContinuousClock.Instant?, work: Work)>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: (due: ContinuousClock.Instant?, work: Work).self,
                                                            bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task.detached(priority: .high) {
            // One latency for every message, so the due times only grow: in order, each on time.
            for await (due, work) in stream {
                if let due { try? await Task.sleep(until: due, clock: .continuous) } // test: the fake wire's one-way delay
                work()
            }
        }
    }

    /// Free delivery's one-way delay (nil: at once). Wall time, for the free-running bench only.
    var latency: Duration? {
        get { lock.withLock { freeLatency } }
        set { lock.withLock { freeLatency = newValue } }
    }

    func send(up isUp: Bool, _ work: @escaping Work) {
        let free = lock.withLock { () -> (Bool, Duration?) in
            guard held else { return (true, freeLatency) }
            if isUp { up.append(work) } else { down.append(work) }
            return (false, nil)
        }
        if free.0 { continuation.yield((due: free.1.map { ContinuousClock.now + $0 }, work: work)) }
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

    /// One live record the Mac streams while the phone switches away and back (the duress rows).
    func streamRecord() -> Data {
        lock.withLock {
            let seq = log.count + 1
            let record = #"{"sessionId":"s1","seq":\#(seq),"at":6,"dir":"mux","kind":"user_message","msg":{"text":"stream \#(seq)","promptId":"ps\#(seq)","turnId":"s\#(seq)"}}"#
            log.append(record)
            return Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":\#(record)}"#.utf8)
        }
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
    private var acceptsParks = false
    private var linkEpoch = 0

    /// The Mac accepts a park (PROTOCOL.md "Parked link"); off, it refuses as an older Mac.
    var parks: Bool {
        get { lock.withLock { acceptsParks } }
        set { lock.withLock { acceptsParks = newValue } }
    }

    /// The links the Mac holds now; `forgetLinks` drops them (a long background:
    /// the phone's old link is gone, so the chain measured is a fresh link's).
    var epoch: Int { lock.withLock { linkEpoch } }
    func forgetLinks() { lock.withLock { linkEpoch += 1 } }

    private var dialCount = 0
    private var keyArrival: ContinuousClock.Instant?
    private weak var latestLink: ChainLink?

    init(macID: String) { self.macID = macID }

    /// Links dialed so far.
    var dials: Int { lock.withLock { dialCount } }
    func dialed(_ link: ChainLink) { lock.withLock { dialCount += 1; latestLink = link } }
    var currentLink: ChainLink? { lock.withLock { latestLink } }

    /// When the Mac's daemon first served a `send` (a typed key) since `resetKey`.
    var keyArrived: ContinuousClock.Instant? { lock.withLock { keyArrival } }
    func resetKey() { lock.withLock { keyArrival = nil } }
    func keyServed() { lock.withLock { if keyArrival == nil { keyArrival = .now } } }

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
        guard let link, !link.isClosed else { throw LinkError(code: "closed", message: "link closed") }
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
private final class ChainLink: ParkableMacLink, @unchecked Sendable {
    let transport: CmuxMobileTransport.TransportKind = .wireGuard
    let connectedPath: LinkPathKind? = .direct
    let states: AsyncStream<LinkState>
    private let stateContinuation: AsyncStream<LinkState>.Continuation
    private let mac: FakeMac
    private let oneWay: Duration
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private let epoch: Int
    private var paired = false
    private var closed = false
    private var held: [@Sendable () -> Void] = []
    private var channels: [ChainChannel] = []
    /// acpmux request id -> method, to name the replies.
    private var methods: [String: String] = [:]
    /// Parked: nothing the Mac sends reaches the phone until it resumes the link (its tunnel
    /// sits on a socket the suspension left behind, and the Mac holds its writes).
    private var parked = false
    private var heldDown: [(ChainChannel, Data)] = []
    private var parks = 0
    private var resumes = 0
    var parkCount: Int { lock.withLock { parks } }
    var resumeCount: Int { lock.withLock { resumes } }

    init(mac: FakeMac) {
        let delay = mac.oneWay
        self.mac = mac
        epoch = mac.epoch
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

    /// A link the Mac forgot never answers (the probe's bound is on the test clock, so it waits
    /// until the link closes).
    func probe(timeout: Duration) async throws -> UInt32? {
        if epoch != mac.epoch {
            try await Task.sleep(for: .seconds(3600))
            return nil
        }
        return try await ping()
    }

    func park(hold: Duration, timeout: Duration) async -> Bool {
        guard mac.parks else { return false }
        lock.withLock {
            parks += 1
            parked = true
        }
        return true
    }

    func resumeParked() -> Bool {
        let held = lock.withLock { () -> [(ChainChannel, Data)]? in
            guard parked else { return nil }
            parked = false
            resumes += 1
            defer { heldDown = [] }
            return heldDown
        }
        guard let held else { return false }
        for (channel, data) in held { toPhone(channel, data) }
        return true
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// The Mac pushes `data` on this link's latest `service` channel (the duress stream).
    func push(service: String, _ data: Data) {
        guard let channel = lock.withLock({ closed ? nil : channels.last { $0.service == service } }) else { return }
        gated { [self] in toPhone(channel, data) }
    }

    func close() async {
        let open = lock.withLock { () -> [ChainChannel] in closed = true; return channels }
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
        let held = lock.withLock { () -> Bool in
            guard parked else { return false }
            heldDown.append((channel, data))
            return true
        }
        guard !held else { return }
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
            case "daemon":
                if Self.objects(data).contains(where: { $0["cmd"] as? String == "send" }) { mac.keyServed() }
                replies = FakeMac.daemon(data)
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
        mac.dialed(link)
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

    /// One coordinator on the fake Mac: paired, chats ready, chat `s1` open with its first live record.
    @MainActor fileprivate struct Rig {
        let live: LiveCoordinator
        let mac: FakeMac
        let clock: LinkTestClock
        let session: MacSession
        let chat: AgentChatStore
        let pick: String

        func stop() {
            live.stop()
            clock.stop()
            UserDefaults.standard.removeObject(forKey: pick)
        }
    }

    fileprivate func rig() async throws -> Rig {
        let userID = "user-\(UUID().uuidString)"
        let teamID = "t-chain-\(UUID().uuidString.prefix(8))"
        let macID = "mac-chain-\(UUID().uuidString.prefix(8).lowercased())"
        let pick = "cmuxMobile.live.mac.\(teamID)"
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

        return Rig(live: live, mac: mac, clock: clock, session: session, chat: chat, pick: pick)
    }

    /// Leo, 2026-11-22: "shit shouldnt somehow instantly dissipate after i navigate away for like
    /// one second". A 1 s app switch keeps the link: with the Mac's answers held (no round trip
    /// yet), the same link, pairing, chats, daemon channel and chat are all still there, so the
    /// first key and the first frame cost no round trip. The old `.resume` closed the link here
    /// and every one of these waited for the chain `reconnectChainAfterForeground` measures.
    @Test func shortResumeKeepsTheLinkWithNoRoundTrip() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let (live, mac, session, chat) = (rig.live, rig.mac, rig.session, rig.chat)
        let kept = try #require(session.link.link) as AnyObject
        let serial = session.workspaces.connectionSerial
        var lines: [String] = []
        for _ in 0..<20 {
            mac.lockstep.hold()
            live.background()
            live.foreground(after: .seconds(1))
            #expect((session.link.link as AnyObject?) === kept, "a 1 s resume replaced the link")
            #expect(session.workspaces.connectionSerial == serial, "a 1 s resume unbound the workspaces")
            #expect(session.workspaces.daemon != nil, "a key typed now would throw no-link")
            #expect(session.pairingState == .paired)
            #expect(session.acpmux.isReady)
            #expect(chat.turns.contains { $0.id == "l0" })
            // The quick probe's pong comes back in one round trip; the link stays.
            mac.lockstep.roundTrip()
            mac.lockstep.release()
            #expect((session.link.link as AnyObject?) === kept)
        }
        lines.append(#"RESUME_KEEP {"away_s":1,"n":20,"round_trips_to_input":0,"round_trips_to_frame":0,"redials":0}"#)
        print(lines[0])
        Attachment.record(lines.joined(separator: "\n"), named: "resume-keep.txt")
    }

    /// Leo, 2026-11-24: back from another app, "the like multi-second long reattach where like
    /// the entire thing is somehow grayed out". The reconnect starts at UIKit's
    /// `willEnterForeground` (before the first frame), and the scene's `.active` after it is a
    /// repeat that neither resumes nor redials again.
    @Test func willEnterForegroundResumesOnceBeforeActive() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let (live, session) = (rig.live, rig.session)
        let kept = try #require(session.link.link) as AnyObject
        let serial = session.workspaces.connectionSerial
        live.background()
        #expect(session.link.isBackgrounded)
        live.willEnterForeground()
        #expect(!session.link.isBackgrounded, "the reconnect waited for the scene's .active")
        live.foreground()
        live.willEnterForeground()
        #expect((session.link.link as AnyObject?) === kept, "the repeat replaced the link")
        #expect(session.workspaces.connectionSerial == serial, "the repeat unbound the workspaces")
        // The next return starts early again.
        live.background()
        #expect(session.link.isBackgrounded)
        live.willEnterForeground()
        #expect(!session.link.isBackgrounded)
        live.foreground()
    }

    @Test func reconnectChainAfterForeground() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let (live, mac, session, chat) = (rig.live, rig.mac, rig.session, rig.chat)

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
                mac.forgetLinks()
                live.background()
                marks.mark("resume")
                // A suspend iOS ended the link of: `.resume` replaces it (a short one keeps it).
                live.foreground(after: nil)
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

/// What a parked link does for work that can't wait for the phone to come back (PROTOCOL.md
/// "Parked link"): a call on the link keeps it out of the park, and a notification action taken in
/// the background resumes it for its request. The fake Mac parks: while parked, nothing it sends
/// reaches the phone until the phone resumes the link. Nothing here brings the scene back.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct ParkedLinkWorkTests {
    /// A coordinator linked to `mac`, paired and with its chats ready.
    private struct Rig {
        let live: LiveCoordinator
        let mac: FakeMac
        let session: MacSession
        let stop: @MainActor () -> Void

        @MainActor var link: ChainLink? { session.link.link as? ChainLink }
    }

    private func rig() async throws -> Rig {
        let userID = "user-\(UUID().uuidString)"
        let teamID = "t-park-\(UUID().uuidString.prefix(8))"
        let macID = "mac-park-\(UUID().uuidString.prefix(8).lowercased())"
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        ServiceStub.install(host: host) { _ in nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-park-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        snapshots.save(LiveSnapshot(
            teamID: teamID, teamName: "One", macs: [MacDevice(id: macID, name: "Studio", isOnline: true)], linkedMacID: macID,
            workspaces: [macID: .init(workspaces: [], savedAt: Date(timeIntervalSince1970: 1_000))]
        ), accountID: userID)
        snapshots.flush()
        let mac = FakeMac(macID: macID)
        let secrets = MemorySecretStore()
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        // No heartbeat, probe bound or retry fires unless the test moves this clock.
        let clock = LinkTestClock()
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: ChainDialer(mac: mac),
            feedStore: FeedStore(items: []),
            keys: PhoneKeys(userID: userID, service: "test.park.\(UUID())", store: secrets, enclave: false),
            snapshots: snapshots, secrets: secrets,
            readMarks: FeedReadMarks(url: directory.appending(path: "read.json")),
            pins: MacPins(file: nil), clock: clock
        )
        live.transcriptCache = nil
        let stop: @MainActor () -> Void = {
            live.stop()
            clock.stop()
            UserDefaults.standard.removeObject(forKey: "cmuxMobile.live.mac.\(teamID)")
        }
        do {
            try await waitFor("the link") { store.macConnection[macID] == .connected }
            let session = try #require(live.session(macID: macID))
            try await waitFor("the pairing") { session.pairingState == .paired }
            try await waitFor("acpmux ready") { session.acpmux.isReady }
            mac.parks = true
            return Rig(live: live, mac: mac, session: session, stop: stop)
        } catch {
            stop()
            throw error
        }
    }

    /// Polls `done` on the main actor until it holds, for at most `within` awake.
    func waitFor(_ what: String, within: Duration = .seconds(30), _ done: () -> Bool) async throws {
        var watchdog = AwakeDeadline(within)
        while !done(), watchdog.hasTimeLeft() { try await Task.sleep(for: .milliseconds(1)) } // test: polls the condition
        try #require(done(), "timed out waiting for \(what)")
    }

    /// Whether a request on the Mac's acpmux comes back within `within`: a reply the Mac
    /// sends on a parked link waits there until the phone resumes it.
    func answers(_ hub: AcpmuxHub, within: Duration) async throws -> Bool {
        var answered = false
        let request = Task { @MainActor in
            _ = try? await hub.request("_acpmux/events", .object(["sessionId": .string("s1")]))
            answered = true
        }
        defer { request.cancel() }
        var watchdog = AwakeDeadline(within)
        while !answered, watchdog.hasTimeLeft() { try await Task.sleep(for: .milliseconds(1)) } // test: polls the condition
        return answered
    }

    /// The phone locks during a call: the call's link is not parked, so the agent's replies
    /// (read aloud) still reach the phone, and it parks once the call ends.
    @Test func aLinkACallUsesIsNotParkedWhenThePhoneLocks() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let link = try #require(rig.link)
        rig.live.setCallMac(rig.mac.macID)
        rig.live.background()
        #expect(try await answers(rig.session.acpmux, within: .seconds(4)), "a reply on the call's link did not arrive")
        #expect(link.parkCount == 0, "the call's link was parked")
        #expect(!rig.session.link.isParked)

        rig.live.setCallMac(nil)
        try await waitFor("the park after the call", within: .seconds(10)) { rig.session.link.isParked }
        #expect(link.parkCount == 1)
    }

    /// A call that starts while the phone is away (Siri, the Action Button) resumes the parked
    /// link, with no redial.
    @Test func aCallStartingOnAParkedLinkResumesIt() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let link = try #require(rig.link)
        rig.live.background()
        try await waitFor("the park", within: .seconds(10)) { rig.session.link.isParked }

        rig.live.setCallMac(rig.mac.macID)
        #expect(!rig.session.link.isParked)
        #expect(link.resumeCount == 1)
        #expect(try await answers(rig.session.acpmux, within: .seconds(4)), "a reply on the call's link did not arrive")
        #expect(rig.link === link, "the call's link was redialed")
    }

    /// Deny on a notification while the app is in the background, on a parked link: the
    /// permission lookup comes back within the reply's budget, and the link parks again after.
    @Test func aBackgroundDenyOnAParkedLinkGetsItsLookupAnswered() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let link = try #require(rig.link)
        rig.live.background()
        try await waitFor("the park", within: .seconds(10)) { rig.session.link.isParked }

        let reply = PushReply(mac: rig.mac.macID, kind: .permission, sessionId: "s1", permissionId: "perm-1",
                              action: .deny(optionID: nil))
        var outcome: Result<Void, any Error>?
        let delivery = Task { @MainActor in
            do {
                try await rig.live.deliver(reply)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
        }
        defer { delivery.cancel() }
        var watchdog = AwakeDeadline(LiveCoordinator.pushReplyBudget)
        while outcome == nil, watchdog.hasTimeLeft() { try await Task.sleep(for: .milliseconds(1)) } // test: polls the condition
        let result = try #require(outcome, "the permission lookup did not answer within the reply's budget")
        // The fake Mac lists nothing pending: the lookup answered, and said so.
        #expect(rig.mac.marks.all["info_in"] != nil, "no answer to _acpmux/info reached the phone")
        if case .failure(let error) = result {
            #expect((error as? LiveCoordinator.PushReplyFailure)?.reason == .refused(String(localized: "This was already answered.")))
        }
        #expect(rig.link === link, "the parked link was redialed")
        try await waitFor("the park after the reply", within: .seconds(10)) { rig.session.link.isParked }
        #expect(link.parkCount == 2)
    }
}

/// One typed key's send; `failed` once it threw (no-link), so the bench sends it again.
@MainActor private final class KeyAttempt { var failed = false }

/// The live resume bench, on the chain suite's rig and fake Mac; its own suite for a longer time limit.
@MainActor
// Runs alone: its wall-time loop holds the main actor for minutes, which starves the timing tests
// beside it. The fleet script turns it on when an only= filter names this suite.
@Suite(.serialized, .timeLimit(.minutes(20)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_RESUME_LIVE_BENCH"] == "1",
                "runs alone: CMUX_RESUME_LIVE_BENCH=1")) struct ResumeLiveBenchTests {
    /// Leo, 2026-11-22: "me swiping up to go to another app then back to the ios cmux internal
    /// app... there's lag when coming back. lag to interaction." Free-running, in wall time, with
    /// the fake Mac 80 ms away (40 ms each way): per app switch, whether the chat kept its content,
    /// how long the first typed key takes to reach the Mac's daemon (through the terminal's `send`
    /// path, retried every 5 ms while it throws no-link), the round trips that took, and the links
    /// dialed. The away time is injected (`foreground(after:)`), never slept: the link machine
    /// decides on it alone. Each row runs twice in the same process: `base` is the pre-fix return
    /// (`foreground(after: nil)` sends `.resume`, which redials every link, the path every return took
    /// before), `after` is the return with its away time. Asserts only that the key lands.
    @Test func resumeLiveBench() async throws {
        let chain = ReconnectChainTimingTests()
        let rig = try await chain.rig()
        defer { rig.stop() }
        let (live, mac, session, chat) = (rig.live, rig.mac, rig.session, rig.chat)
        let oneWayMillis = 40.0
        mac.oneWay = .milliseconds(Int(oneWayMillis))
        mac.lockstep.latency = .milliseconds(Int(oneWayMillis))
        let pre = chat.turns.map(\.id)
        try #require(pre.contains("l0"))
        func millis(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        func settled() -> Bool {
            session.pairingState == .paired && session.acpmux.isReady && session.workspaces.daemon != nil
                && session.link.link != nil
        }
        var report: [String] = []
        let rows: [(away: Int, duress: Bool)] = [(1, false), (5, false), (30, false), (300, false), (1, true), (30, true)]
        for mode in ["base", "after"] { for row in rows {
            var keyMillis: [Double] = []
            var roundTrips: [Double] = []
            var kept = 0
            var reconnects = 0
            for _ in 0..<20 {
                try await chain.waitFor("the link to settle before a switch") { settled() }
                try await Task.sleep(for: .milliseconds(200)) // test: lets the last switch's probe and replies drain
                // Duress: the Mac streams a live record every 10 ms, from before the switch until the key lands.
                let streaming: Task<Void, Never>? = row.duress ? Task.detached(priority: .high) {
                    while !Task.isCancelled {
                        mac.currentLink?.push(service: "acpmux", mac.acpmux.streamRecord())
                        try? await Task.sleep(for: .milliseconds(10)) // test: the stream's cadence
                    }
                } : nil
                if row.duress { try await Task.sleep(for: .milliseconds(50)) } // test: the stream runs before the switch
                mac.resetKey()
                let dialsBefore = mac.dials
                live.background()
                live.foreground(after: mode == "base" ? nil : .seconds(row.away))
                let start = ContinuousClock.now
                // The screen's model, read on every pass until the key lands: never cleared.
                var contentKept = pre.allSatisfy { id in chat.turns.contains { $0.id == id } }
                var attempt: KeyAttempt?
                var watchdog = AwakeDeadline(.seconds(10))
                while mac.keyArrived == nil, watchdog.hasTimeLeft() {
                    if attempt == nil || attempt!.failed {
                        let next = KeyAttempt()
                        attempt = next
                        let serial = session.workspaces.connectionSerial
                        Task { @MainActor in
                            // The terminal's typing path (TerminalFeed.type): this connection's daemon channel.
                            guard let type = session.terminalFeed.type else { next.failed = true; return }
                            do { try await type(1, Data("x".utf8), serial) } catch { next.failed = true }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(5)) // test: the retry cadence of a key that threw no-link
                    if !pre.allSatisfy({ id in chat.turns.contains { $0.id == id } }) { contentKept = false }
                }
                streaming?.cancel()
                let landed = try #require(mac.keyArrived, "the first key never reached the Mac within 10 s (away \(row.away) s)")
                let ms = millis(landed - start)
                keyMillis.append(ms)
                // Serial round trips the key waited for: its time on the wire past the one way it travels, in RTTs.
                roundTrips.append(max(0, ((ms - oneWayMillis) / (2 * oneWayMillis)).rounded()))
                if contentKept { kept += 1 }
                try await chain.waitFor("the link to settle after the key") { settled() }
                reconnects += mac.dials - dialsBefore
            }
            let line = #"RESUME_LIVE {"mode":"\#(mode)","away_s":\#(row.away),"n":20,"duress":\#(row.duress),"content_kept":\#(kept),"first_key_p50_ms":\#(ReconnectChainTimingTests.fmt(ReconnectChainTimingTests.percentile(keyMillis, 0.5))),"first_key_p95_ms":\#(ReconnectChainTimingTests.fmt(ReconnectChainTimingTests.percentile(keyMillis, 0.95))),"round_trips_p95":\#(Int(ReconnectChainTimingTests.percentile(roundTrips, 0.95))),"reconnects":\#(reconnects),"rtt_ms":80,"away":"injected, not slept"}"#
            print(line)
            report.append(line)
        } }
        Attachment.record(report.joined(separator: "\n"), named: "resume-live.txt")
    }
}
#endif
