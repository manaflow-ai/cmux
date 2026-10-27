import CmuxFuzzSupport
import CmuxNextMobile
import Foundation

nonisolated enum HostFuzz {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hexDigits = Set("0123456789abcdef")

    /// An id of any characters, at least one.
    static func id(_ rng: inout FuzzRNG) -> String {
        "i" + FuzzJSON.randomString(&rng, limit: 12)
    }

    /// A phone key as hostd sends it (65 bytes X9.63 as lowercase hex), or now and then any text.
    static func key(_ rng: inout FuzzRNG) -> String {
        guard !rng.oneIn(4) else { return FuzzJSON.randomString(&rng, limit: 140) }
        return "04" + rng.bytes(count: 64).map { String(format: "%02x", $0) }.joined()
    }

    /// The approval-key fingerprint is 16 lowercase hex digits for any key text.
    static func checkFingerprint(_ key: String) throws {
        let fingerprint = MobileHostPairedDevices.fingerprint(key)
        try FuzzRun.check(fingerprint.count == 16 && fingerprint.allSatisfy(hexDigits.contains), "fingerprint \(fingerprint) of \(key)")
    }
}

/// One generated hostd status line (`control.rs` `Event`, snake case) and the event it must decode to.
/// Every field of the line is strict: a field of the wrong type, or a missing field the event needs,
/// makes the line decode to nothing.
nonisolated struct HostLineSample {
    nonisolated enum Kind: CaseIterable {
        case connecting, online, waiting, needToken, needAcpmux, phoneUp, phonePath, phoneMedia, phoneDown, pairRequest
        case unpaired, needBrowser, browserStop, needSurface, surfaceStop, removed, unknown
    }

    static let linkKinds: [Kind] = [.phoneUp, .phoneUp, .phonePath, .phoneMedia, .phoneDown]
    /// One time in this many a strict optional field gets a value of the wrong type.
    static let wrongOdds = 40

    var line: FuzzJSON
    var expected: MobileHostEvent?

    init(_ rng: inout FuzzRNG, kinds: [Kind] = Kind.allCases, session: String? = nil, phone: String? = nil) {
        var f = FuzzRecord()
        let kind = rng.element(of: kinds) ?? .connecting
        let event: MobileHostEvent?
        let type: String
        switch kind {
        case .connecting:
            type = "connecting"
            event = .connecting
        case .online:
            let device = HostFuzz.id(&rng), team = HostFuzz.id(&rng)
            f.require("device_id", .string(device), &rng)
            f.require("team_id", .string(team), &rng)
            type = "online"
            event = .online(deviceID: device, teamID: team)
        case .waiting:
            let reason = Self.text("reason", &f, &rng) ?? ""
            let retryValue = rng.int(in: Int.min...Int.max)
            let retry = f.optional("retry_in_seconds", .int(Int64(retryValue)), decoded: retryValue, &rng, wrongOdds: Self.wrongOdds)
            type = "waiting"
            event = .waiting(reason: reason, retryInSeconds: retry ?? 0)
        case .needToken:
            type = "need_token"
            event = .needToken
        case .needAcpmux:
            type = "need_acpmux"
            event = .needAcpmux
        case .phoneUp:
            let sessionID = session ?? HostFuzz.id(&rng), phoneID = phone ?? HostFuzz.id(&rng)
            f.require("session_id", .string(sessionID), &rng)
            f.require("phone_device_id", .string(phoneID), &rng)
            let transport = Self.text("transport", &f, &rng, choices: ["webrtc", "wireguard"]) ?? ""
            let path = Self.text("path", &f, &rng, choices: ["direct", "relay", "turn"]) ?? ""
            let link = MobileHostPhoneLink(sessionID: sessionID, phoneDeviceID: phoneID, transport: transport, path: path)
            type = "phone_up"
            event = .phoneUp(link)
        case .phonePath:
            let sessionID = session ?? HostFuzz.id(&rng)
            let anyPath = FuzzJSON.randomString(&rng)
            let path = rng.element(of: ["direct", "relay", "turn", anyPath]) ?? "direct"
            f.require("session_id", .string(sessionID), &rng)
            f.require("path", .string(path), &rng)
            type = "phone_path"
            event = .phonePath(sessionID: sessionID, path: path)
        case .phoneMedia:
            let sessionID = session ?? HostFuzz.id(&rng)
            let anyMedia = FuzzJSON.randomString(&rng)
            let media = rng.element(of: ["direct", "turn", "none", anyMedia]) ?? "none"
            f.require("session_id", .string(sessionID), &rng)
            f.require("media_path", .string(media), &rng)
            type = "phone_media"
            event = .phoneMedia(sessionID: sessionID, mediaPath: media == "none" ? nil : media)
        case .phoneDown:
            let sessionID = session ?? HostFuzz.id(&rng)
            f.require("session_id", .string(sessionID), &rng)
            let reason = Self.text("reason", &f, &rng) ?? ""
            type = "phone_down"
            event = .phoneDown(sessionID: sessionID, reason: reason)
        case .pairRequest:
            let phoneID = phone ?? HostFuzz.id(&rng)
            let identity = HostFuzz.key(&rng), approval = HostFuzz.key(&rng)
            let request = Self.pair(&f, phone: phoneID, identityKey: identity, approvalKey: approval, &rng)
            type = "pair_request"
            event = .pairRequest(request)
        case .unpaired:
            let phoneID = phone ?? HostFuzz.id(&rng)
            f.require("phone_device_id", .string(phoneID), &rng)
            type = "unpaired"
            event = .unpaired(phoneDeviceID: phoneID)
        case .needBrowser:
            let request = rng.next(), tab = HostFuzz.id(&rng)
            f.require("request", .uint(request), &rng)
            f.require("tab", .string(tab), &rng)
            let url = Self.text("url", &f, &rng, choices: ["https://example.com/", "about:blank"]) ?? "about:blank"
            type = "need_browser"
            event = .needBrowser(request: request, tab: tab, url: url)
        case .browserStop:
            let tab = HostFuzz.id(&rng)
            f.require("tab", .string(tab), &rng)
            type = "browser_stop"
            event = .browserStop(tab: tab)
        case .needSurface:
            let request = rng.next(), tab = HostFuzz.id(&rng)
            f.require("request", .uint(request), &rng)
            f.require("tab", .string(tab), &rng)
            type = "need_surface"
            event = .needSurface(request: request, tab: tab)
        case .surfaceStop:
            let tab = HostFuzz.id(&rng)
            f.require("tab", .string(tab), &rng)
            type = "surface_stop"
            event = .surfaceStop(tab: tab)
        case .removed:
            type = "removed"
            event = .removed
        case .unknown:
            type = "x_" + rng.text(Array("abcxyz_"), 10)
            event = nil
        }
        f.require("type", .string(type), &rng, odds: 24)
        f.noise(&rng)
        line = f.json
        expected = f.complete ? event : nil
    }

    /// A strict optional string field: one of `choices` or any text, missing, null, or (rarely) mistyped.
    static func text(_ key: String, _ f: inout FuzzRecord, _ rng: inout FuzzRNG, choices: [String] = []) -> String? {
        let value = rng.oneIn(3) ? FuzzJSON.randomString(&rng) : (rng.element(of: choices) ?? FuzzJSON.randomString(&rng))
        return f.optional(key, .string(value), decoded: value, &rng, wrongOdds: wrongOdds)
    }

    /// A `pair_request`'s fields: the phone and its two keys are required, its name and registration optional.
    static func pair(_ f: inout FuzzRecord, phone: String, identityKey: String, approvalKey: String,
                     _ rng: inout FuzzRNG) -> MobileHostPairRequest {
        f.require("phone_device_id", .string(phone), &rng)
        f.require("identity_key", .string(identityKey), &rng)
        f.require("approval_key", .string(approvalKey), &rng)
        let name = text("name", &f, &rng, choices: ["iPhone", "Lawrence’s iPhone", String(repeating: "n", count: 200)]) ?? ""
        let milliseconds = Int64(truncatingIfNeeded: rng.next())
        let registered = f.optional("registered_at_ms", .int(milliseconds), decoded: milliseconds, &rng, wrongOdds: wrongOdds)
        return MobileHostPairRequest(phoneDeviceID: phone, name: name, identityKey: identityKey, approvalKey: approvalKey,
                                     registeredAt: registered.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
    }

    /// A pair request line for `phone` with these keys.
    static func pairLine(_ rng: inout FuzzRNG, phone: String, identityKey: String, approvalKey: String) -> HostLineSample {
        var f = FuzzRecord()
        let request = pair(&f, phone: phone, identityKey: identityKey, approvalKey: approvalKey, &rng)
        f.require("type", .string("pair_request"), &rng, odds: 24)
        f.noise(&rng)
        return HostLineSample(line: f.json, expected: f.complete ? .pairRequest(request) : nil)
    }

    init(line: FuzzJSON, expected: MobileHostEvent?) {
        self.line = line
        self.expected = expected
    }

    func check() throws {
        let text = try line.text()
        let decoded = MobileHostEvent(line: text)
        try FuzzRun.check(decoded == expected, "\(text) decoded to \(String(describing: decoded)), not \(String(describing: expected))")
        try HostRawLine.check(Data(text.utf8))
    }
}

/// Any bytes as one line of hostd's stdout, read as the supervisor reads it: an event or nothing, and
/// an event folds into the state and the pairing values without a trap.
nonisolated enum HostRawLine {
    static let seeds: [Data] = [
        #"{"type":"connecting"}"#,
        #"{"type":"online","device_id":"mac-1","team_id":"team-1"}"#,
        #"{"type":"waiting","reason":"signaling closed","retry_in_seconds":5}"#,
        #"{"type":"need_token"}"#,
        #"{"type":"phone_up","session_id":"s1","phone_device_id":"p1","transport":"wireguard","path":"direct"}"#,
        #"{"type":"phone_path","session_id":"s1","path":"turn"}"#,
        #"{"type":"phone_media","session_id":"s1","media_path":"none"}"#,
        #"{"type":"phone_down","session_id":"s1","reason":"closed"}"#,
        #"{"type":"pair_request","phone_device_id":"p1","name":"iPhone","identity_key":"04ab","approval_key":"04cd","registered_at_ms":1800000000000}"#,
        #"{"type":"unpaired","phone_device_id":"p1"}"#,
        #"{"type":"need_browser","request":7,"tab":"t1","url":"https://example.com"}"#,
        #"{"type":"need_surface","request":8,"tab":"t2"}"#,
        #"{"type":"removed"}"#,
    ].map { Data($0.utf8) }

    static let tokens: [Data] = [
        "\"type\"", "\"session_id\"", "\"phone_device_id\"", "\"pair_request\"", "\"phone_up\"", "\"phone_down\"",
        "\"identity_key\"", "\"approval_key\"", "\"registered_at_ms\"", "\"request\"", "\"tab\"", "\"none\"", "\"removed\"",
    ].map { Data($0.utf8) }

    static func check(_ bytes: Data) throws {
        let line = String(decoding: bytes, as: UTF8.self)
        guard let event = MobileHostEvent(line: line) else { return }
        var state = MobileHostState(phase: .online)
        state.apply(event, at: HostFuzz.now)
        guard case let .pairRequest(request) = event else { return }
        try HostFuzz.checkFingerprint(request.approvalKey)
        var prompts = MobileHostPairPrompts()
        try FuzzRun.check(prompts.receive(request, at: HostFuzz.now) == .ask, "a first request was not asked")
        var paired = MobileHostPairedDevices(userID: "user-1")
        paired.approve(request, at: HostFuzz.now)
        try FuzzRun.check(paired.decision(for: request) == .trusted, "an allowed request is not trusted")
    }
}

/// Several phones' link lines, some damaged, between other status lines and mutated ones.
nonisolated struct HostPhonesCase {
    nonisolated struct Step {
        var line: String
        /// The phone the line is about, when the generator knows it.
        var phone: String?
        var damaged: Bool
    }

    var steps: [Step] = []

    init(_ rng: inout FuzzRNG) throws {
        let phones = (0..<(2 + rng.below(3))).map { index in "phone\(index)-" + HostFuzz.id(&rng) }
        var sessions: [String: [String]] = [:]
        let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + HostRawLine.tokens, maximumCount: 2_048)
        for _ in 0..<(1 + rng.below(30)) {
            let phone = rng.element(of: phones) ?? "phone0"
            switch rng.below(8) {
            case 0...5:
                let known = sessions[phone] ?? []
                let session = !known.isEmpty && !rng.oneIn(3) ? (rng.element(of: known) ?? "") : "\(phone)/s\(known.count)"
                if !known.contains(session) { sessions[phone, default: []].append(session) }
                let sample = HostLineSample(&rng, kinds: HostLineSample.linkKinds, session: session, phone: phone)
                steps.append(Step(line: try sample.line.text(), phone: phone, damaged: sample.expected == nil))
            case 6:
                let sample = HostLineSample(&rng, kinds: [.connecting, .online, .waiting, .needToken, .pairRequest, .needBrowser, .removed])
                steps.append(Step(line: try sample.line.text(), phone: nil, damaged: sample.expected == nil))
            default:
                let base = rng.element(of: HostRawLine.seeds) ?? Data()
                steps.append(Step(line: String(decoding: mutator.mutate(base, using: &rng), as: UTF8.self), phone: nil, damaged: false))
            }
        }
    }

    /// The links after `event`, as ``MobileHostState`` documents them: a link comes up (replacing its own
    /// session's), moves path or media, goes down, and all go when the Mac is removed.
    static func links(_ links: [MobileHostPhoneLink], after event: MobileHostEvent) -> [MobileHostPhoneLink] {
        switch event {
        case var .phoneUp(link):
            link.since = HostFuzz.now
            return links.filter { $0.sessionID != link.sessionID } + [link]
        case let .phonePath(session, path):
            return links.map { link in
                var moved = link
                if link.sessionID == session { moved.path = path }
                return moved
            }
        case let .phoneMedia(session, media):
            return links.map { link in
                var moved = link
                if link.sessionID == session { moved.mediaPath = media }
                return moved
            }
        case let .phoneDown(session, _):
            return links.filter { $0.sessionID != session }
        case .removed:
            return []
        default:
            return links
        }
    }

    func check() throws {
        var state = MobileHostState(phase: .online)
        var links: [MobileHostPhoneLink] = []
        for step in steps {
            let event = MobileHostEvent(line: step.line)
            if step.damaged { try FuzzRun.check(event == nil, "the damaged line \(step.line) decoded to \(String(describing: event))") }
            let before = state.phones
            if let event {
                state.apply(event, at: HostFuzz.now)
                links = Self.links(links, after: event)
            }
            try FuzzRun.check(state.phones == links, "after \(step.line): links \(state.phones), not \(links)")
            if let phone = step.phone {
                let others = before.filter { $0.phoneDeviceID != phone }
                try FuzzRun.check(state.phones.filter { $0.phoneDeviceID != phone } == others,
                                  "a line about \(phone) changed another phone's link: \(step.line)")
            }
        }
    }
}
