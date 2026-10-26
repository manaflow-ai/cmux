import CmuxFuzzSupport
@testable import CmuxNextDevices
import Foundation

nonisolated enum HubFuzz {
    /// Every kind but a string: what a string field must skip.
    static let notString: [FuzzJSON.Kind] = [.null, .bool, .number, .array, .object]

    /// An id of any characters, at least one, never only dots (a dot segment, which the hub never issues).
    static func id(_ rng: inout FuzzRNG) -> String {
        let id = FuzzJSON.randomString(&rng, limit: 12)
        return id.isEmpty || id.allSatisfy({ $0 == "." }) ? "d" + id : id
    }

    /// Letters, digits and `-`: a URL path segment or header value that needs no escaping.
    static func plain(_ rng: inout FuzzRNG, limit: Int = 12) -> String {
        "p" + rng.text(Array("abcxyz019-"), limit)
    }

    /// A date field as the hub sends it (unix seconds, unix milliseconds or ISO 8601) and the date it means.
    static func date(_ rng: inout FuzzRNG) -> (FuzzJSON, Date) {
        switch rng.below(3) {
        case 0:
            let seconds = rng.int(in: 0...4_000_000_000)
            return (.int(Int64(seconds)), Date(timeIntervalSince1970: Double(seconds)))
        case 1:
            let milliseconds = rng.int(in: 100_000_000_001...9_000_000_000_000)
            return (.int(Int64(milliseconds)), Date(timeIntervalSince1970: Double(milliseconds) / 1000))
        default:
            let date = Date(timeIntervalSince1970: Double(rng.int(in: 0...4_000_000_000)))
            return (.string(ISO8601DateFormatter().string(from: date)), date)
        }
    }
}

/// One generated push frame and the push it must decode to (nil: it must decode to nothing).
nonisolated struct HubPushSample {
    enum Kind: CaseIterable {
        case devicesChanged, permissionsChanged, relaysChanged, request, ticket, denied, revoked, ended, pong, unknown
    }

    static let sessionKinds: [Kind] = [.request, .ticket, .denied, .revoked, .ended, .pong, .unknown]

    var frame: FuzzJSON
    var expected: DeviceHubPush?

    init(_ rng: inout FuzzRNG, kinds: [Kind] = Kind.allCases, sessionID: String? = nil) {
        let session = sessionID ?? HubFuzz.id(&rng)
        var envelope = FuzzRecord()
        let kind = rng.element(of: kinds) ?? .pong
        let type: String
        let push: DeviceHubPush?
        switch kind {
        case .devicesChanged:
            type = "devices.changed"
            push = .devicesChanged
        case .permissionsChanged:
            type = "permissions.changed"
            let host = HubFuzz.id(&rng)
            push = .permissionsChanged(hostID: envelope.optional("hostId", .string(host), decoded: host, &rng))
        case .relaysChanged:
            type = "relays.changed"
            push = .relaysChanged
        case .request:
            type = "session.request"
            var body = FuzzRecord()
            let request = Self.request(&body, id: session, &rng)
            envelope.require("session", body.json, &rng, odds: 16)
            push = body.complete ? .sessionRequest(request) : nil
        case .ticket:
            type = "session.ticket"
            push = Self.ticket(&envelope, id: session, &rng).map(DeviceHubPush.sessionTicket)
        case .denied:
            type = "session.denied"
            envelope.require("sessionId", .string(session), &rng)
            push = .sessionDenied(sessionID: session)
        case .revoked, .ended:
            type = kind == .revoked ? "session.revoked" : "session.ended"
            envelope.require("sessionId", .string(session), &rng)
            let text = FuzzJSON.randomString(&rng)
            let reason = envelope.optional("reason", .string(text), decoded: text, &rng)
            push = kind == .revoked ? .sessionRevoked(sessionID: session, reason: reason)
                : .sessionEnded(sessionID: session, reason: reason)
        case .pong:
            type = "pong"
            push = .pong
        case .unknown:
            type = "x." + HubFuzz.plain(&rng)
            push = .unknown(type)
        }
        envelope.require("type", .string(type), &rng, odds: 24)
        envelope.noise(&rng)
        frame = envelope.json
        expected = envelope.complete ? push : nil
    }

    /// A `session.request`'s `session`: the ids are required, the rest lenient.
    static func request(_ body: inout FuzzRecord, id: String, _ rng: inout FuzzRNG) -> SessionRequest {
        body.require("id", .string(id), &rng)
        let viewer = HubFuzz.id(&rng)
        body.require("viewerId", .string(viewer), &rng)
        let name = FuzzJSON.randomString(&rng)
        let viewerName = body.lenient("viewerName", .string(name), decoded: name, otherwise: "", wrong: HubFuzz.notString, &rng)
        let keyPrint = FuzzJSON.randomString(&rng)
        let fingerprint = body.lenient("viewerKeyFingerprint", .string(keyPrint), decoded: Optional(keyPrint), otherwise: nil,
                                       wrong: HubFuzz.notString, &rng)
        let scope = rng.element(of: ["view", "full", "ask", "none", ""]) ?? "view"
        let decodedScope = body.lenient("scope", .string(scope), decoded: SessionScope(rawValue: scope) ?? .view, otherwise: .view,
                                        wrong: HubFuzz.notString, &rng)
        body.noise(&rng)
        return SessionRequest(id: id, viewerId: viewer, viewerName: viewerName, viewerKeyFingerprint: fingerprint, scope: decodedScope)
    }

    /// A `session.ticket` (a synthesized decoder: every field required and strict, the ICE servers lenient).
    static func ticket(_ envelope: inout FuzzRecord, id: String, _ rng: inout FuzzRNG) -> SessionTicket? {
        envelope.require("sessionId", .string(id), &rng)
        let jws = rng.text(Array("abcXYZ019-_."), 40)
        envelope.require("ticket", .string(jws), &rng)
        let signal = "wss://hub.example/v1/sessions/\(HubFuzz.plain(&rng))/ws"
        envelope.require("signalURL", .string(signal), &rng)
        var servers: [FuzzJSON] = []
        var ice: [DeviceHubICEServer] = []
        for _ in 0..<rng.below(3) {
            let (json, server) = iceServer(&rng)
            servers.append(json)
            ice.append(server)
        }
        envelope.require("ice", .array(servers), &rng)
        var peer = FuzzRecord()
        let peerID = HubFuzz.id(&rng), peerName = FuzzJSON.randomString(&rng), key = FuzzJSON.randomString(&rng)
        peer.require("id", .string(peerID), &rng, odds: 24)
        peer.require("name", .string(peerName), &rng, odds: 24)
        peer.require("signingKey", .string(key), &rng, odds: 24)
        envelope.require("peer", peer.json, &rng, odds: 24)
        let role = rng.oneIn(16) ? "admin" : (rng.bool() ? "viewer" : "host")
        envelope.require("role", .string(role), &rng, odds: 24)
        let scope = rng.oneIn(16) ? "ask" : (rng.bool() ? "view" : "full")
        envelope.require("scope", .string(scope), &rng, odds: 24)
        guard peer.complete, let url = URL(string: signal), let decodedRole = SessionTicket.Role(rawValue: role),
              let decodedScope = SessionScope(rawValue: scope) else {
            envelope.complete = false
            return nil
        }
        return SessionTicket(sessionId: id, ticket: jws, signalURL: url, ice: ice,
                             peer: .init(id: peerID, name: peerName, signingKey: key), role: decodedRole, scope: decodedScope)
    }

    /// One ICE server: `urls` a list, one string or of another type (no URL), the credentials lenient.
    static func iceServer(_ rng: inout FuzzRNG) -> (FuzzJSON, DeviceHubICEServer) {
        var fields = FuzzRecord()
        let list = (0..<rng.below(3)).map { _ in "turn:" + HubFuzz.plain(&rng) + ":3478" }
        let urls: [String]
        switch rng.below(3) {
        case 0:
            fields.fields["urls"] = .array(list.map { FuzzJSON.string($0) })
            urls = list
        case 1:
            let one = "stun:" + HubFuzz.plain(&rng)
            fields.fields["urls"] = .string(one)
            urls = [one]
        default:
            urls = fields.lenient("urls", .null, decoded: [], otherwise: [], wrong: [.null, .bool, .number, .object], &rng)
        }
        let user = FuzzJSON.randomString(&rng), secret = FuzzJSON.randomString(&rng)
        let username = fields.lenient("username", .string(user), decoded: Optional(user), otherwise: nil, wrong: HubFuzz.notString, &rng)
        let credential = fields.lenient("credential", .string(secret), decoded: Optional(secret), otherwise: nil,
                                        wrong: HubFuzz.notString, &rng)
        fields.noise(&rng)
        return (fields.json, DeviceHubICEServer(urls: urls, username: username, credential: credential))
    }

    func check() throws {
        let text = try frame.text()
        let decoded = DeviceHubPush(text: text)
        try FuzzRun.check(decoded == expected, "\(text) decoded to \(String(describing: decoded)), not \(String(describing: expected))")
        try HubRawFrame.check(text)
    }
}

/// Any text as a socket frame: it decodes to a push or to nothing, and a ticket's socket URL carries its ticket.
nonisolated enum HubRawFrame {
    static let seeds: [Data] = [
        #"{"type":"devices.changed"}"#,
        #"{"type":"permissions.changed","hostId":"h1"}"#,
        #"{"type":"session.request","session":{"id":"s1","viewerId":"v1","viewerName":"Phone","viewerKeyFingerprint":"AB12","scope":"full"}}"#,
        #"{"type":"session.ticket","sessionId":"s1","ticket":"h.p.s","signalURL":"wss://hub.example/v1/sessions/s1/ws","ice":[{"urls":["turn:cf:3478"],"username":"u","credential":"c"}],"peer":{"id":"h1","name":"Studio","signingKey":"BASE64"},"role":"viewer","scope":"view"}"#,
        #"{"type":"session.revoked","sessionId":"s1","reason":"device_removed"}"#,
        #"{"type":"session.ended","sessionId":"s1"}"#,
        #"{"type":"pong"}"#,
    ].map { Data($0.utf8) }

    static let tokens: [Data] = [
        "\"type\"", "\"session\"", "\"sessionId\"", "\"session.ticket\"", "\"session.request\"", "\"signalURL\"",
        "\"ice\"", "\"urls\"", "\"peer\"", "\"role\"", "\"scope\"", "\"viewerId\"", "\"wss://\"",
    ].map { Data($0.utf8) }

    static let ticketCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    static func check(_ text: String) throws {
        guard case let .sessionTicket(ticket)? = DeviceHubPush(text: text) else { return }
        let url = ticket.signalSocketURL
        // A compact JWS is base64url and dots, and the hub's signal URL has a host; anything else only has to give a URL.
        guard ticket.ticket.allSatisfy(ticketCharacters.contains), ticket.signalURL.host?.isEmpty == false else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        try FuzzRun.check(items.last == URLQueryItem(name: "ticket", value: ticket.ticket),
                          "\(url) does not end with the ticket \(ticket.ticket)")
    }
}

/// A scripted User DO socket: good, damaged and mutated frames, then the server's close 4001 (removed),
/// which ends ``DeviceHubSocket/run(_:)`` without a reconnect.
nonisolated struct HubSocketCase {
    var frames: [String] = []
    var expected: [DeviceHubPush] = []

    init(_ rng: inout FuzzRNG) throws {
        let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + HubRawFrame.tokens, maximumCount: 4_096)
        for _ in 0..<(1 + rng.below(12)) {
            switch rng.below(4) {
            case 0, 1:
                let sample = HubPushSample(&rng)
                frames.append(try sample.frame.text())
                if let push = sample.expected { expected.append(push) }
            case 2:
                let base = rng.element(of: HubRawFrame.seeds) ?? Data()
                let text = String(decoding: mutator.mutate(base, using: &rng), as: UTF8.self)
                frames.append(text)
                if let push = DeviceHubPush(text: text) { expected.append(push) }
            default:
                let text = String(decoding: rng.bytes(64), as: UTF8.self)
                frames.append(text)
                if let push = DeviceHubPush(text: text) { expected.append(push) }
            }
        }
    }

    func check() async throws {
        let connection = ScriptedHubConnection(frames)
        let connector = OneHubConnector(connection: connection)
        let socket = DeviceHubSocket(connector: connector, pingInterval: .seconds(3600))
        let log = Locked<[DeviceHubSocket.Event]>([])
        await socket.run { event in log.set(log.value + [event]) }
        let want: [DeviceHubSocket.Event] = [.state(.connecting), .state(.connected)] + expected.map(DeviceHubSocket.Event.push)
            + [.state(.removed)]
        try FuzzRun.check(log.value == want, "the socket gave \(log.value), not \(want), for \(frames)")
        try FuzzRun.check(connector.attempts.value == 1, "the socket connected \(connector.attempts.value) times")
        try FuzzRun.check(connection.remaining.value.isEmpty, "the socket stopped reading before the server closed it")
        try FuzzRun.check(connection.closed.value, "the socket was not closed after the server closed it")
    }
}

/// Hands out its frames, then fails as the server's close 4001.
nonisolated struct ScriptedHubConnection: DeviceHubSocketConnection {
    let remaining: Locked<[String]>
    let closed = Locked(false)

    init(_ frames: [String]) {
        remaining = Locked(frames)
    }

    func receive() async throws -> String {
        let frames = remaining.value
        guard let next = frames.first else { throw DeviceHubSocket.Closed(code: 4001) }
        remaining.set(Array(frames.dropFirst()))
        return next
    }

    func send(_ text: String) async throws {}

    func close() { closed.set(true) }
}

/// One connection; any later connect fails.
nonisolated struct OneHubConnector: DeviceHubSocketConnector {
    let connection: ScriptedHubConnection
    let attempts = Locked(0)

    func connect() async throws -> any DeviceHubSocketConnection {
        attempts.set(attempts.value + 1)
        guard attempts.value == 1 else { throw URLError(.cannotConnectToHost) }
        return connection
    }
}

/// Session frames for several sessions, some damaged, read by a real ``DeviceHubSocket`` and handed to
/// ``DeviceHub`` as the app hands them (`DeviceHub.start`: `socket.run { hub.handle($0) }`).
nonisolated struct HubSessionsCase: Sendable {
    var frames: [String] = []
    /// What the generator made frame `i` decode to; nil for a damaged frame, which the socket must drop.
    var expected: [DeviceHubPush?] = []

    init(_ rng: inout FuzzRNG) throws {
        let sessions = (0..<(2 + rng.below(3))).map { index in "s\(index)-" + HubFuzz.id(&rng) }
        for _ in 0..<(1 + rng.below(24)) {
            let session = rng.element(of: sessions) ?? "s0"
            let sample = HubPushSample(&rng, kinds: HubPushSample.sessionKinds, sessionID: session)
            frames.append(try sample.frame.text())
            expected.append(sample.expected)
        }
    }

    /// The hub's session state after each push equals the contract's, folded from the generator's own
    /// pushes: a request waits until its session gets a ticket or ends; a ticket stays until its session
    /// is denied, revoked or ends. A damaged frame gives no push, so it changes nothing.
    @MainActor func play(on stub: StubHub) async throws {
        let hub = DeviceHub(client: makeClient(stub), secrets: MemoryRelaySecretStore(), deviceName: "Studio", now: fixedNow)
        let seen = Locked<[DeviceHubPush]>([])
        hub.onSessionPush = { seen.set(seen.value + [$0]) }
        let socket = DeviceHubSocket(connector: OneHubConnector(connection: ScriptedHubConnection(frames)),
                                     pingInterval: .seconds(3600))
        let observed = Locked<[HubSessionState]>([])
        await socket.run { event in
            await hub.handle(event)
            guard case .push = event else { return }
            let state = await HubSessionState(hub, seen: seen.value)
            observed.set(observed.value + [state])
        }

        // The socket's `.connected` counts as one push (the hub reads everything again on it).
        var want = HubSessionState(pushCount: 1)
        var states: [HubSessionState] = []
        for push in expected.compactMap({ $0 }) {
            want.fold(push)
            states.append(want)
        }
        let got = observed.value
        try FuzzRun.check(got.count == states.count, "the hub got \(got.count) pushes, not \(states.count), for \(frames)")
        for (index, (state, wanted)) in zip(got, states).enumerated() {
            try FuzzRun.check(state == wanted, "after push \(index) of \(frames): \(state), not \(wanted)")
        }
        try FuzzRun.check(hub.connection == .removed, "the socket ended as \(hub.connection), not removed")
    }
}

/// The session part of ``DeviceHub``: its waiting requests, tickets, push count and what its session layer saw.
nonisolated struct HubSessionState: Sendable, Equatable, CustomStringConvertible {
    var pending: [SessionRequest] = []
    var tickets: [String: SessionTicket] = [:]
    var pushCount = 0
    var sessionPushes: [DeviceHubPush] = []

    init(pushCount: Int) {
        self.pushCount = pushCount
    }

    @MainActor init(_ hub: DeviceHub, seen: [DeviceHubPush]) {
        pending = hub.pendingRequests
        tickets = hub.tickets
        pushCount = hub.pushCount
        sessionPushes = seen
    }

    /// The contract of each session push (PROTOCOL.md), stated per case.
    mutating func fold(_ push: DeviceHubPush) {
        if push != .pong { pushCount += 1 }
        switch push {
        case let .sessionRequest(request):
            if !pending.contains(where: { $0.id == request.id }) { pending.append(request) }
            sessionPushes.append(push)
        case let .sessionTicket(ticket):
            pending.removeAll { $0.id == ticket.sessionId }
            tickets[ticket.sessionId] = ticket
            sessionPushes.append(push)
        case let .sessionDenied(id), let .sessionRevoked(id, _), let .sessionEnded(id, _):
            pending.removeAll { $0.id == id }
            tickets[id] = nil
            sessionPushes.append(push)
        default:
            break
        }
    }

    var description: String {
        "requests \(pending.map(\.id)), tickets \(tickets.keys.sorted()), \(pushCount) pushes, the session layer saw \(sessionPushes.count)"
    }
}
