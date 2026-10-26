import CmuxFuzzSupport
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation

/// Pair requests from several phones (retries, key rotations, garbage keys, damaged lines, more phones
/// than may wait), the person's answers, sign-outs and time passing, run through the iPhone host's
/// pairing values as ``IPhoneHostService`` runs them (`ask`, `decide`, `revokePhone`).
nonisolated struct HostPairingCase {
    nonisolated enum Step {
        case line(String, phone: String, damaged: Bool)
        case answer(phone: String, allow: Bool)
        case wait(TimeInterval)
    }

    /// What one phone has in the pairing values: its waiting request, its paired entry and its refusals.
    nonisolated struct PhoneState: Equatable {
        var pending: MobileHostPairRequest?
        var device: MobileHostPairedDevice?
        var denied: [MobileHostPairedDevices.Denied]

        init(_ phone: String, _ prompts: MobileHostPairPrompts, _ paired: MobileHostPairedDevices) {
            pending = prompts.request(id: phone)
            device = paired.devices.first { $0.id == phone }
            denied = paired.denied.filter { $0.id == phone }
        }
    }

    var phones: [String]
    var steps: [Step] = []

    init(_ rng: inout FuzzRNG) throws {
        phones = (0..<(2 + rng.below(5))).map { index in "phone\(index)-" + HostFuzz.id(&rng) }
        var keys: [String: (String, String)] = [:]
        for _ in 0..<(1 + rng.below(40)) {
            let phone = rng.element(of: phones) ?? "phone0"
            switch rng.below(10) {
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
            default:
                steps.append(.wait(TimeInterval(rng.int(in: 0...1_200))))
            }
        }
    }

    func check() throws {
        var prompts = MobileHostPairPrompts()
        var paired = MobileHostPairedDevices(userID: "user-1")
        var now = HostFuzz.now
        for step in steps {
            let before = (prompts: prompts, paired: paired)
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
                    try Self.receive(request, prompts: &prompts, paired: paired, at: now)
                case let .unpaired(id)?:
                    try FuzzRun.check(id == phone, "\(line) names \(id)")
                    prompts.forget(id: id)
                    paired.remove(id)
                    try FuzzRun.check(PhoneState(id, prompts, paired).pending == nil && PhoneState(id, prompts, paired).device == nil,
                                      "a signed-out phone still waits or is paired")
                case nil:
                    break
                case let other?:
                    throw FuzzError.property("a pairing line decoded to \(other)", location: "HostPairingCase")
                }
            case let .answer(phone, allow):
                subject = phone
                if let request = prompts.answer(id: phone, allowed: allow, at: now) {
                    if allow { paired.approve(request, at: now) } else { paired.deny(request) }
                    try FuzzRun.check(paired.decision(for: request) == (allow ? .trusted : .denied), "an answered request decides \(paired.decision(for: request))")
                    try FuzzRun.check(allow || prompts.isQuiet(at: now), "Don't Allow did not quiet the prompts")
                }
            case let .wait(seconds):
                now = now.addingTimeInterval(seconds)
            }
            try check(prompts, paired, before: before, subject: subject)
        }
    }

    /// A request the list does not decide yet: a waiting phone's request is replaced (new keys) or
    /// repeated, a new phone waits unless prompts are quiet or full, when it is counted as blocked.
    static func receive(_ request: MobileHostPairRequest, prompts: inout MobileHostPairPrompts, paired: MobileHostPairedDevices,
                        at now: Date) throws {
        guard paired.decision(for: request) == .ask else { return }
        let waiting = prompts.request(id: request.phoneDeviceID)
        let quiet = prompts.isQuiet(at: now), full = prompts.pending.count >= MobileHostPairPrompts.limit, blocked = prompts.blocked
        let outcome = prompts.receive(request, at: now)
        if let waiting {
            try FuzzRun.check(outcome == .repeated, "a waiting phone's request gave \(outcome)")
            let held = prompts.request(id: request.phoneDeviceID)
            try FuzzRun.check(held == (waiting.sameKeys(as: request) ? waiting : request), "the waiting request is \(String(describing: held))")
        } else if quiet || full {
            try FuzzRun.check(outcome == .blocked && prompts.blocked == blocked + 1, "a request while quiet or full gave \(outcome)")
        } else {
            try FuzzRun.check(outcome == .ask && prompts.pending.last == request, "a new phone's request gave \(outcome)")
        }
    }

    /// The bounds hold, and nothing of any phone but `subject` changed.
    private func check(_ prompts: MobileHostPairPrompts, _ paired: MobileHostPairedDevices,
                       before: (prompts: MobileHostPairPrompts, paired: MobileHostPairedDevices), subject: String?) throws {
        let waiting = prompts.pending.map(\.phoneDeviceID)
        try FuzzRun.check(waiting.count <= MobileHostPairPrompts.limit, "\(waiting.count) phones wait")
        try FuzzRun.check(Set(waiting).count == waiting.count, "a phone waits twice: \(waiting)")
        try FuzzRun.check(Set(paired.devices.map(\.id)).count == paired.devices.count, "a phone is paired twice")
        try FuzzRun.check(prompts.blocked >= before.prompts.blocked, "the blocked count went down")
        let approvers = paired.approversParams(macDevice: "mac-1")["approvers"] as? [[String: String]]
        try FuzzRun.check(approvers?.count == paired.devices.count, "acpmux would get \(String(describing: approvers?.count)) approvers")
        guard let subject else { return }
        for phone in phones where phone != subject {
            try FuzzRun.check(PhoneState(phone, prompts, paired) == PhoneState(phone, before.prompts, before.paired),
                              "a step for \(subject) changed \(phone)")
        }
        let others = { (list: [MobileHostPairRequest]) in list.filter { $0.phoneDeviceID != subject } }
        try FuzzRun.check(others(prompts.pending) == others(before.prompts.pending), "a step for \(subject) reordered other phones")
    }
}

/// One generated shipped-iOS RPC frame (`{"id","method","params","auth"?}`) and what the request must read.
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
            switch rng.below(5) {
            case 0:
                let text = FuzzJSON.randomString(&rng)
                params[key] = .string(text)
                strings[key] = text.isEmpty ? nil : text
                ints[key] = Int(text, radix: 10)
            case 1:
                let digits = String(rng.int(in: -1_000_000...1_000_000))
                params[key] = .string(digits)
                strings[key] = digits
                ints[key] = Int(digits, radix: 10)
            case 2:
                let number = rng.oneIn(4) ? Int64(truncatingIfNeeded: rng.next()) : Int64(rng.int(in: -1_000...1_000))
                params[key] = .int(number)
                strings[key] = .some(nil)
                ints[key] = Int(exactly: Double(number).rounded())
            case 3:
                let value = rng.double(in: -1e6...1e6)
                params[key] = .double(value)
                strings[key] = .some(nil)
                ints[key] = Int(exactly: value.rounded())
            default:
                params[key] = FuzzJSON.random(&rng, of: [.null, .bool, .array, .object])
                strings[key] = .some(nil)
                ints[key] = .some(nil)
            }
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

/// The paired-phones file and the test seed file with damaged contents.
nonisolated struct HostFilesCase {
    var paired: Data
    var seed: Data
    var seedIsIntact: Bool
    var request: MobileHostPairRequest

    init(_ rng: inout FuzzRNG) throws {
        let phone = HostFuzz.id(&rng), name = FuzzJSON.randomString(&rng)
        let identity = HostFuzz.key(&rng), approval = HostFuzz.key(&rng)
        request = MobileHostPairRequest(phoneDeviceID: phone, name: name, identityKey: identity, approvalKey: approval)
        var list = MobileHostPairedDevices(userID: rng.oneIn(4) ? "user-2" : "user-1")
        list.approve(request, at: HostFuzz.now)
        let other = MobileHostPairRequest(phoneDeviceID: HostFuzz.id(&rng), name: "", identityKey: HostFuzz.key(&rng),
                                          approvalKey: HostFuzz.key(&rng))
        list.deny(other)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stored = try encoder.encode(list)
        let mutator = FuzzMutator(dictionary: FuzzJSON.tokens + ["\"devices\"", "\"denied\"", "\"userID\"", "\"pairedAt\""].map { Data($0.utf8) },
                                  maximumCount: 16_384)
        paired = rng.oneIn(4) ? stored : mutator.mutate(stored, using: &rng)
        let intact = try FuzzJSON.object(["devices": .array([.object(["id": .string(phone)])])]).data()
        seedIsIntact = rng.oneIn(4)
        seed = seedIsIntact ? intact : mutator.mutate(intact, using: &rng)
    }

    func check(in directory: URL) throws {
        let file = MobileHostPairedDevicesFile(directory: directory)
        try paired.write(to: file.file)
        let loaded = file.load(userID: "user-1")
        var want = MobileHostPairedDevices(userID: "user-1")
        if let stored = try? JSONDecoder().decode(MobileHostPairedDevices.self, from: paired), stored.userID == "user-1" { want = stored }
        try FuzzRun.check(loaded == want, "the paired file loaded as \(loaded), not \(want)")

        let seedFile = directory.appendingPathComponent("seed.json")
        try seed.write(to: seedFile)
        let trusts = IPhonePairingSeed(file: seedFile).trusts(request)
        let parses = (try? JSONDecoder().decode(IPhonePairingSeed.File.self, from: seed)) != nil
        try FuzzRun.check(parses || !trusts, "a seed that does not parse trusted a phone")
        try FuzzRun.check(!seedIsIntact || trusts, "the seed naming the phone did not trust it")
    }
}
