import CmuxFuzzSupport
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation

/// Pair requests from several phones (retries, key rotations, garbage keys, damaged lines, more phones
/// than may wait), the person's answers, sign-outs, Settings removals, iPhone connections turned off and
/// on, and time passing, run through ``MobileHostPairing``: the value `IPhoneHostService` holds and asks
/// for every pairing decision (`pairingEvent` asks or revokes, `answerPairRequest` decides, `revokePhone`
/// revokes). The case also starts signed out, or signed in as another user than the list's, now and then.
nonisolated struct HostPairingCase {
    nonisolated enum Step {
        case line(String, phone: String, damaged: Bool)
        case answer(phone: String, allow: Bool)
        case remove(phone: String)
        case allowConnections(Bool)
        case wait(TimeInterval)
    }

    /// What one phone has in the pairing: its waiting request, its paired entry and its refusals.
    nonisolated struct PhoneState: Equatable {
        var pending: MobileHostPairRequest?
        var device: MobileHostPairedDevice?
        var denied: [MobileHostPairedDevices.Denied]

        init(_ phone: String, _ pairing: MobileHostPairing) {
            pending = pairing.prompts.request(id: phone)
            device = pairing.paired?.devices.first { $0.id == phone }
            denied = pairing.paired?.denied.filter { $0.id == phone } ?? []
        }

        /// The list holds exactly these keys for the phone.
        func trusts(_ request: MobileHostPairRequest) -> Bool {
            device?.identityKey == request.identityKey && device?.approvalKey == request.approvalKey
        }

        /// The list refused this identity key of the phone.
        func refuses(_ request: MobileHostPairRequest) -> Bool {
            denied.contains { $0.identityKey == request.identityKey }
        }
    }

    var phones: [String]
    /// Phones the DEBUG test seed trusts.
    var seeded: Set<String> = []
    var start: MobileHostPairing
    /// The signed-in user: the list's own ("user-1") mostly.
    var userID: String?
    var steps: [Step] = []

    init(_ rng: inout FuzzRNG) throws {
        phones = (0..<(2 + rng.below(5))).map { index in "phone\(index)-" + HostFuzz.id(&rng) }
        if rng.oneIn(3), let phone = rng.element(of: phones) { seeded.insert(phone) }
        start = MobileHostPairing(paired: rng.oneIn(8) ? nil : MobileHostPairedDevices(userID: "user-1"))
        userID = rng.oneIn(8) ? (rng.bool() ? nil : "user-2") : "user-1"
        var keys: [String: (String, String)] = [:]
        for _ in 0..<(1 + rng.below(40)) {
            let phone = rng.element(of: phones) ?? "phone0"
            switch rng.below(12) {
            case 0...4:
                // A retry keeps a key, a rotation draws a new one.
                var identity = HostFuzz.key(&rng), approval = HostFuzz.key(&rng)
                if let kept = keys[phone], !rng.oneIn(4) { identity = kept.0 }
                if let kept = keys[phone], !rng.oneIn(4) { approval = kept.1 }
                keys[phone] = (identity, approval)
                let sample = HostLineSample.pairLine(&rng, phone: phone, identityKey: identity, approvalKey: approval)
                steps.append(.line(try sample.line.text(), phone: phone, damaged: sample.expected == nil))
            case 5, 6:
                steps.append(.answer(phone: phone, allow: rng.bool()))
            case 7:
                let sample = HostLineSample(&rng, kinds: [.unpaired], phone: phone)
                steps.append(.line(try sample.line.text(), phone: phone, damaged: sample.expected == nil))
            case 8:
                steps.append(.remove(phone: phone))
            case 9:
                steps.append(.allowConnections(!rng.oneIn(4)))
            default:
                steps.append(.wait(TimeInterval(rng.int(in: 0...1_200))))
            }
        }
    }

    func check() throws {
        var pairing = start
        var allowed = true
        var now = HostFuzz.now
        for step in steps {
            let before = pairing
            var subject: String?
            switch step {
            case let .line(line, phone, damaged):
                subject = phone
                let event = MobileHostEvent(line: line)
                if damaged { try FuzzRun.check(event == nil, "the damaged line \(line) decoded to \(String(describing: event))") }
                switch event {
                case let .pairRequest(request)?:
                    try FuzzRun.check(request.phoneDeviceID == phone, "\(line) names \(request.phoneDeviceID)")
                    try HostFuzz.checkFingerprint(request.approvalKey)
                    let asked = pairing.ask(request, allowed: allowed, userID: userID, at: now) { seeded.contains($0.phoneDeviceID) }
                    try checkAsk(request, asked, allowed: allowed, before: before, after: pairing, at: now)
                case let .unpaired(id)?:
                    try FuzzRun.check(id == phone, "\(line) names \(id)")
                    try checkRevoke(id, changed: pairing.revoke(id: id), before: before, after: pairing)
                case nil:
                    break
                case let other?:
                    throw FuzzError.property("a pairing line decoded to \(other)", location: "HostPairingCase")
                }
            case let .answer(phone, allow):
                subject = phone
                // `answerPairRequest(id:allow:)`: only a waiting request is answered.
                if let request = pairing.prompts.request(id: phone) {
                    let changed = pairing.decide(request, allow: allow, userID: userID, at: now)
                    try checkDecide(request, allow: allow, changed: changed, before: before, after: pairing, at: now)
                }
            case let .remove(phone):
                subject = phone
                try checkRevoke(phone, changed: pairing.revoke(id: phone), before: before, after: pairing)
            case let .allowConnections(on):
                allowed = on
            case let .wait(seconds):
                now = now.addingTimeInterval(seconds)
            }
            try checkBounds(pairing, before: before, subject: subject)
        }
    }

    /// A request: ignored while connections are off or no one is signed in; nothing new when the list
    /// already holds or refused its keys; paired from the seed only into the signed-in user's own list;
    /// else a waiting phone's request is replaced (new keys) or repeated, and a new phone waits unless
    /// prompts are quiet or full, when it is counted as blocked.
    private func checkAsk(_ request: MobileHostPairRequest, _ asked: MobileHostPairing.Ask, allowed: Bool,
                          before: MobileHostPairing, after: MobileHostPairing, at now: Date) throws {
        let phone = request.phoneDeviceID
        let was = PhoneState(phone, before), state = PhoneState(phone, after)
        guard allowed, let list = before.paired else {
            try FuzzRun.check(asked == .ignored && after == before, "a request with connections off or signed out gave \(asked)")
            return
        }
        if was.trusts(request) || was.refuses(request) {
            try FuzzRun.check(asked == .known && after == before, "a request the list decides gave \(asked)")
            return
        }
        if seeded.contains(phone), list.userID == userID {
            try FuzzRun.check(asked == .seeded && state.trusts(request) && after.prompts == before.prompts,
                              "a seeded phone's request gave \(asked)")
            return
        }
        try FuzzRun.check(after.paired == before.paired, "a prompted request changed the list")
        let quiet = before.prompts.isQuiet(at: now), full = before.prompts.pending.count >= MobileHostPairPrompts.limit
        if let waiting = was.pending {
            try FuzzRun.check(asked == .prompted(.repeated), "a waiting phone's request gave \(asked)")
            let held = state.pending
            try FuzzRun.check(held == (waiting.sameKeys(as: request) ? waiting : request), "the waiting request is \(String(describing: held))")
        } else if quiet || full {
            try FuzzRun.check(asked == .prompted(.blocked) && after.prompts.blocked == before.prompts.blocked + 1,
                              "a request while quiet or full gave \(asked)")
        } else {
            try FuzzRun.check(asked == .prompted(.ask) && after.prompts.pending.last == request, "a new phone's request gave \(asked)")
        }
    }

    /// An answer: the request stops waiting, Don't Allow quiets the prompts, and the answer is written
    /// only to the signed-in user's own list (Allow: these keys; Don't Allow: this identity key refused).
    private func checkDecide(_ request: MobileHostPairRequest, allow: Bool, changed: Bool,
                             before: MobileHostPairing, after: MobileHostPairing, at now: Date) throws {
        let phone = request.phoneDeviceID
        let was = PhoneState(phone, before), state = PhoneState(phone, after)
        try FuzzRun.check(state.pending == nil, "an answered request still waits")
        try FuzzRun.check(allow || after.prompts.isQuiet(at: now), "Don't Allow did not quiet the prompts")
        guard let list = before.paired, list.userID == userID else {
            try FuzzRun.check(!changed && after.paired == before.paired, "an answer changed another user's list")
            return
        }
        try FuzzRun.check(changed, "an answer to the user's own list changed nothing")
        if allow {
            try FuzzRun.check(state.trusts(request) && state.denied.isEmpty, "Allow left \(state)")
        } else {
            try FuzzRun.check(state.device == was.device && state.refuses(request), "Don't Allow left \(state)")
        }
    }

    /// A sign-out or a removal: the phone neither waits nor stays paired; its refusals stay.
    private func checkRevoke(_ phone: String, changed: Bool, before: MobileHostPairing, after: MobileHostPairing) throws {
        let was = PhoneState(phone, before), state = PhoneState(phone, after)
        try FuzzRun.check(state.pending == nil && state.device == nil, "a forgotten phone still waits or is paired")
        try FuzzRun.check(state.denied == was.denied, "forgetting a phone changed its refusals")
        try FuzzRun.check(changed == (before.paired != nil), "a revoke with a list reported \(changed)")
        try FuzzRun.check(after.paired?.userID == before.paired?.userID, "a revoke changed the list's user")
    }

    /// The bounds hold, and nothing of any phone but `subject` changed.
    private func checkBounds(_ after: MobileHostPairing, before: MobileHostPairing, subject: String?) throws {
        let waiting = after.prompts.pending.map(\.phoneDeviceID)
        try FuzzRun.check(waiting.count <= MobileHostPairPrompts.limit, "\(waiting.count) phones wait")
        try FuzzRun.check(Set(waiting).count == waiting.count, "a phone waits twice: \(waiting)")
        try FuzzRun.check(after.prompts.blocked >= before.prompts.blocked, "the blocked count went down")
        if let paired = after.paired {
            try FuzzRun.check(Set(paired.devices.map(\.id)).count == paired.devices.count, "a phone is paired twice")
            let approvers = paired.approversParams(macDevice: "mac-1")["approvers"] as? [[String: String]]
            try FuzzRun.check(approvers?.count == paired.devices.count, "acpmux would get \(String(describing: approvers?.count)) approvers")
        }
        guard let subject else { return }
        for phone in phones where phone != subject {
            try FuzzRun.check(PhoneState(phone, after) == PhoneState(phone, before), "a step for \(subject) changed \(phone)")
        }
        let others = { (list: [MobileHostPairRequest]) in list.filter { $0.phoneDeviceID != subject } }
        try FuzzRun.check(others(after.prompts.pending) == others(before.prompts.pending), "a step for \(subject) reordered other phones")
    }
}

/// One generated shipped-iOS RPC frame (`{"id","method","params","auth"?}`) and what the request must read.
/// Each parameter's expected string and integer is chosen with the value, never computed from it: digit
/// strings of a known integer, whole numbers, halves (rounded away from zero), quarters (rounded to the
/// nearer integer) and numbers past `Int`'s range (none).
nonisolated struct HostRPCSample {
    static let seeds: [Data] = [
        #"{"id":1,"method":"workspace.list","params":{}}"#,
        #"{"id":"a","method":"terminal.input","params":{"surface_id":"s1","text":"ls\n","rows":"24"}}"#,
        #"{"id":null,"method":"host.info","auth":{"token":"t"}}"#,
        #"{"method":"terminal.resize","params":{"cols":80.4,"rows":-1e3}}"#,
    ].map { Data($0.utf8) }

    static let tokens: [Data] = ["\"method\"", "\"params\"", "\"id\"", "\"auth\""].map { Data($0.utf8) }

    var frame: FuzzJSON
    var method: String?
    /// What `string(key)` and `int(key)` must give for each parameter the frame has.
    var strings: [String: String?] = [:]
    var ints: [String: Int?] = [:]

    init(_ rng: inout FuzzRNG) {
        var f = FuzzRecord()
        let anyMethod = FuzzJSON.randomString(&rng)
        let name = rng.element(of: ["workspace.list", "terminal.input", "host.info", "", anyMethod]) ?? ""
        f.require("method", .string(name), &rng)
        if rng.bool() { f.fields["id"] = FuzzJSON.random(&rng) }
        if rng.oneIn(4) { f.fields["auth"] = FuzzJSON.random(&rng) }
        var params: [String: FuzzJSON] = [:]
        for index in 0..<rng.below(5) {
            let key = "p\(index)"
            let (value, string, int) = Self.parameter(&rng)
            params[key] = value
            strings[key] = .some(string)
            ints[key] = .some(int)
        }
        if rng.oneIn(10) {
            // Parameters that are not an object read as none.
            f.fields["params"] = FuzzJSON.random(&rng, notOf: [.object])
            strings = strings.mapValues { _ in nil }
            ints = ints.mapValues { _ in nil }
        } else if !params.isEmpty || rng.bool() {
            f.fields["params"] = .object(params)
        }
        f.noise(&rng)
        frame = f.json
        method = f.complete ? name : nil
    }

    /// One parameter value with the string and the integer it reads as.
    static func parameter(_ rng: inout FuzzRNG) -> (FuzzJSON, String?, Int?) {
        let whole = rng.int(in: 0...1_000_000), negative = rng.bool()
        let signed = negative ? -whole : whole, sign: Double = negative ? -1 : 1
        switch rng.below(8) {
        case 0:
            // Text that is not a number: it starts with a letter.
            let text = "a" + FuzzJSON.randomString(&rng)
            return (.string(text), text, nil)
        case 1:
            return (.string(""), nil, nil)
        case 2:
            let digits = String(signed)
            return (.string(digits), digits, signed)
        case 3:
            return (.int(Int64(signed)), nil, signed)
        case 4:
            // m + 0.5 rounds away from zero to m + 1.
            return (.double(sign * (Double(whole) + 0.5)), nil, negative ? -(whole + 1) : whole + 1)
        case 5:
            // m + 0.25 rounds to m.
            return (.double(sign * (Double(whole) + 0.25)), nil, signed)
        case 6:
            // Past Int's range in either direction, as a float or as a 64-bit unsigned integer.
            let past: FuzzJSON = rng.bool() ? .double(sign * 1e19) : .uint(UInt64.max - UInt64(rng.below(1_000)))
            return (past, nil, nil)
        default:
            return (FuzzJSON.random(&rng, of: [.null, .bool, .array, .object]), nil, nil)
        }
    }

    func check() throws {
        let data = try frame.data()
        let request = MobileRPCRequest(frame: data)
        let text = String(decoding: data, as: UTF8.self)
        try FuzzRun.check(request?.method == method, "\(text) gave method \(String(describing: request?.method))")
        guard let request else { return }
        for (key, want) in strings {
            try FuzzRun.check(request.string(key) == want, "\(text): string(\(key)) is \(String(describing: request.string(key)))")
        }
        for (key, want) in ints {
            try FuzzRun.check(request.int(key) == want, "\(text): int(\(key)) is \(String(describing: request.int(key)))")
        }
        try Self.checkRaw(data)
    }

    /// Any bytes: a request or nothing, and every parameter reads as a string and an integer without a trap.
    static func checkRaw(_ frame: Data) throws {
        guard let request = MobileRPCRequest(frame: frame) else { return }
        for key in request.params.keys {
            _ = request.string(key)
            _ = request.int(key)
        }
    }
}

/// The paired-phones file and the test seed file, as stored and damaged.
nonisolated struct HostFilesCase {
    nonisolated enum PairedFile {
        /// Written by `MobileHostPairedDevicesFile.save`: loads as stored for its user, empty for another.
        case saved
        /// A strict prefix of the saved bytes: never a JSON object, so it loads empty.
        case truncated(Data)
        /// Token-mutated bytes: any list of the signed-in user, never a trap.
        case mutated(Data)
    }

    nonisolated enum SeedFile {
        /// The seed names the phone by id (any case) or by name: it trusts the request.
        case names(Data)
        /// The seed names another phone, an entry with nothing in it, or the phone with another
        /// identity key: it trusts no request of this phone.
        case other(Data)
        /// Token-mutated bytes: trusts or not, never a trap.
        case mutated(Data)
    }

    var list: MobileHostPairedDevices
    var paired: PairedFile
    var seed: SeedFile
    var request: MobileHostPairRequest

    init(_ rng: inout FuzzRNG) throws {
        let phone = HostFuzz.id(&rng), name = FuzzJSON.randomString(&rng)
        let identity = HostFuzz.key(&rng), approval = HostFuzz.key(&rng)
        request = MobileHostPairRequest(phoneDeviceID: phone, name: name, identityKey: identity, approvalKey: approval)
        list = MobileHostPairedDevices(userID: rng.oneIn(4) ? "user-2" : "user-1")
        list.approve(request, at: HostFuzz.now)
        let other = MobileHostPairRequest(phoneDeviceID: HostFuzz.id(&rng), name: "", identityKey: HostFuzz.key(&rng),
                                          approvalKey: HostFuzz.key(&rng))
        list.deny(other)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stored = try encoder.encode(list)
        let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + ["\"devices\"", "\"denied\"", "\"userID\"", "\"pairedAt\""].map { Data($0.utf8) },
                                  maximumCount: 16_384)
        switch rng.below(3) {
        case 0: paired = .saved
        case 1: paired = .truncated(stored.prefix(rng.below(stored.count)))
        default: paired = .mutated(mutator.mutate(stored, using: &rng))
        }

        let entryKind = rng.below(6)
        let names = entryKind < 3
        let entry: FuzzJSON = switch entryKind {
        case 0: .object(["id": .string(phone)])
        case 1: .object(["id": .string(phone.uppercased())])
        case 2: .object(["name": .string(name)])
        case 3: .object(["id": .string("other-" + phone)])
        case 4: .object([:])
        default: .object(["id": .string(phone), "identityKey": .string(identity.lowercased() + "0")])
        }
        let seedBytes = try FuzzJSON.object(["devices": .array([entry])]).data()
        if rng.oneIn(4) {
            seed = .mutated(mutator.mutate(seedBytes, using: &rng))
        } else {
            seed = names ? .names(seedBytes) : .other(seedBytes)
        }
    }

    func check(in directory: URL) throws {
        let file = MobileHostPairedDevicesFile(directory: directory, seal: MobileHostMemoryPairingSeal())
        let empty = MobileHostPairedDevices(userID: "user-1")
        switch paired {
        case .saved:
            try file.save(list)
            let loaded = file.load(userID: "user-1")
            try FuzzRun.check(loaded == (list.userID == "user-1" ? list : empty), "the saved list of \(list.userID) loaded as \(loaded)")
            try FuzzRun.check(file.load(userID: "user-3") == MobileHostPairedDevices(userID: "user-3"), "another user loaded the list")
        case let .truncated(bytes):
            try bytes.write(to: file.file)
            let loaded = file.load(userID: "user-1")
            try FuzzRun.check(loaded == empty, "a cut-off file loaded as \(loaded)")
        case let .mutated(bytes):
            try bytes.write(to: file.file)
            let loaded = file.load(userID: "user-1")
            try FuzzRun.check(loaded.userID == "user-1", "a damaged file loaded the list of \(loaded.userID)")
        }

        let seedFile = directory.appendingPathComponent("seed.json")
        switch seed {
        case let .names(bytes):
            try bytes.write(to: seedFile)
            try FuzzRun.check(IPhonePairingSeed(file: seedFile).trusts(request), "a seed naming the phone did not trust it")
        case let .other(bytes):
            try bytes.write(to: seedFile)
            try FuzzRun.check(!IPhonePairingSeed(file: seedFile).trusts(request), "a seed naming another phone trusted this one")
        case let .mutated(bytes):
            try bytes.write(to: seedFile)
            _ = IPhonePairingSeed(file: seedFile).trusts(request)
        }
    }
}
