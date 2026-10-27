import CmuxFuzzSupport
@testable import CmuxNextDevices
import Foundation

/// The hub's HTTP records with any value in any field. The ids a record needs decide whether it decodes;
/// every other field is lenient (PROTOCOL.md: "a newer server never breaks an older app"), so a value of
/// the wrong type gives that field's default and leaves the others as sent.
nonisolated enum HubRecordCase {
    static let dateWrong: [FuzzJSON.Kind] = [.null, .bool, .string, .array, .object]
    static let flagWrong: [FuzzJSON.Kind] = [.null, .string, .array, .object]

    static func check(_ rng: inout FuzzRNG) throws {
        let json: FuzzJSON
        switch rng.below(9) {
        case 0:
            let (record, device) = Self.device(&rng)
            try FuzzRun.check(try decode(HubDevice.self, record) == device, "\(record) is not \(String(describing: device))")
            json = record
        case 1:
            let (record, relay) = Self.relay(&rng)
            try FuzzRun.check(try decode(HubRelay.self, record) == relay, "\(record) is not \(String(describing: relay))")
            json = record
        case 2:
            json = try lenientRecord(HubPermission.self, required: ["viewerId"], lenient: ["hostId", "scope"], &rng)
        case 3:
            json = try lenientRecord(HubSession.self, required: ["id"], lenient: ["state", "scope"], &rng)
        case 4:
            json = try lenientRecord(AuditEntry.self, required: ["id"], lenient: [
                "ts", "event", "viewerId", "hostId", "deviceId", "viewerName", "hostName", "deviceName", "scope", "sessionId",
                "detail", "durationS", "duration_s",
            ], &rng)
        case 5:
            json = try lenientRecord(HubMe.self, required: ["userId"], lenient: ["plan", "device"], &rng)
        case 6:
            json = try lenientRecord(DeviceHubICEServer.self, required: [], lenient: ["urls", "username", "credential"], &rng)
        case 7:
            json = try relaySecret(&rng)
        default:
            json = try errorBody(&rng)
        }
        try mutated(json, &rng)
    }

    /// The value `json` decodes to as `T`, nil when it does not.
    static func decode<T: Decodable>(_ type: T.Type, _ json: FuzzJSON) throws -> T? {
        try? JSONDecoder().decode(T.self, from: json.data())
    }

    /// A record whose `required` ids are strings (or, sometimes, missing or mistyped) and whose `lenient`
    /// fields hold any value: it decodes exactly when the ids are there.
    static func lenientRecord<T: Decodable>(_ type: T.Type, required: [String], lenient: [String],
                                            _ rng: inout FuzzRNG) throws -> FuzzJSON {
        var fields = FuzzRecord()
        for key in required {
            let id = HubFuzz.id(&rng)
            fields.require(key, .string(id), &rng, odds: 6)
        }
        for key in lenient where rng.bool() { fields.fields[key] = FuzzJSON.random(&rng) }
        fields.noise(&rng)
        let decoded = try decode(T.self, fields.json) != nil
        try FuzzRun.check(decoded == fields.complete, "\(T.self) from \(fields.json): decoded \(decoded)")
        return fields.json
    }

    static func device(_ rng: inout FuzzRNG) -> (FuzzJSON, HubDevice?) {
        var f = FuzzRecord()
        let id = HubFuzz.id(&rng)
        f.require("id", .string(id), &rng, odds: 6)
        let nameText = FuzzJSON.randomString(&rng)
        let name = f.lenient("name", .string(nameText), decoded: nameText, otherwise: "", wrong: HubFuzz.notString, &rng)
        let platformText = rng.element(of: ["macos", "ios", "android", ""]) ?? ""
        let platform = f.lenient("platform", .string(platformText), decoded: DevicePlatform(rawValue: platformText), otherwise: nil,
                                 wrong: HubFuzz.notString, &rng)
        let signingText = FuzzJSON.randomString(&rng)
        let signing = f.lenient("signingKey", .string(signingText), decoded: Optional(signingText), otherwise: nil,
                                wrong: HubFuzz.notString, &rng)
        let agreementText = FuzzJSON.randomString(&rng)
        let agreement = f.lenient("agreementKey", .string(agreementText), decoded: Optional(agreementText), otherwise: nil,
                                  wrong: HubFuzz.notString, &rng)
        let (createdJSON, created) = HubFuzz.date(&rng)
        let createdAt = f.lenient("createdAt", createdJSON, decoded: Optional(created), otherwise: nil, wrong: dateWrong, &rng)
        let (seenJSON, seen) = HubFuzz.date(&rng)
        let lastSeenAt = f.lenient("lastSeenAt", seenJSON, decoded: Optional(seen), otherwise: nil, wrong: dateWrong, &rng)
        let (sharedJSON, sharedValue) = flag(&rng)
        let shared = f.lenient("macScreenShared", sharedJSON, decoded: sharedValue, otherwise: false, wrong: flagWrong, &rng)
        let (onlineJSON, onlineValue) = flag(&rng)
        let online = f.lenient("online", onlineJSON, decoded: onlineValue, otherwise: false, wrong: flagWrong, &rng)
        f.noise(&rng)
        let device = HubDevice(id: id, name: name, platform: platform, signingKey: signing, agreementKey: agreement,
                               createdAt: createdAt, lastSeenAt: lastSeenAt, macScreenShared: shared, online: online)
        return (f.json, f.complete ? device : nil)
    }

    static func relay(_ rng: inout FuzzRNG) -> (FuzzJSON, HubRelay?) {
        var f = FuzzRecord()
        let id = HubFuzz.id(&rng)
        f.require("id", .string(id), &rng, odds: 6)
        let nameText = FuzzJSON.randomString(&rng)
        let name = f.lenient("name", .string(nameText), decoded: nameText, otherwise: "", wrong: HubFuzz.notString, &rng)
        let list = (0..<rng.below(3)).map { _ in "turn:" + HubFuzz.plain(&rng) }
        let urls = f.lenient("urls", .array(list.map { FuzzJSON.string($0) }), decoded: list, otherwise: [],
                             wrong: [.null, .bool, .number, .string, .object], &rng)
        let modeText = rng.element(of: ["shared_secret", "static", "turn"]) ?? "static"
        let mode = f.lenient("authMode", .string(modeText), decoded: RelayAuthMode(rawValue: modeText) ?? .static, otherwise: .static,
                             wrong: HubFuzz.notString, &rng)
        let blob = FuzzJSON.randomString(&rng)
        let sealedJSON: FuzzJSON = rng.bool() ? .string(blob) : .object([HubFuzz.id(&rng): .string(blob)])
        let sealed = f.lenient("sealed", sealedJSON, decoded: Optional(blob), otherwise: nil, wrong: [.null, .bool, .number, .array], &rng)
        let (enabledJSON, enabledValue) = flag(&rng)
        let enabled = f.lenient("enabled", enabledJSON, decoded: enabledValue, otherwise: true, wrong: flagWrong, &rng)
        let priorityValue = rng.int(in: -1_000...1_000)
        let priority = f.lenient("priority", .int(Int64(priorityValue)), decoded: priorityValue, otherwise: 0,
                                 wrong: [.null, .bool, .string, .array, .object], &rng)
        let (updatedJSON, updated) = HubFuzz.date(&rng)
        let updatedAt = f.lenient("updatedAt", updatedJSON, decoded: Optional(updated), otherwise: nil, wrong: dateWrong, &rng)
        f.noise(&rng)
        let relay = HubRelay(id: id, name: name, urls: urls, authMode: mode, sealedForThisDevice: sealed, enabled: enabled,
                             priority: priority, updatedAt: updatedAt)
        return (f.json, f.complete ? relay : nil)
    }

    /// A flag as `true`/`false` or as SQLite's integers, and what it means.
    static func flag(_ rng: inout FuzzRNG) -> (FuzzJSON, Bool) {
        if rng.bool() {
            let value = rng.bool()
            return (.bool(value), value)
        }
        let value = rng.int(in: -3...3)
        return (.int(Int64(value)), value != 0)
    }

    /// A relay secret (strict): its mode decides which fields it needs; it survives a round trip.
    static func relaySecret(_ rng: inout FuzzRNG) throws -> FuzzJSON {
        var f = FuzzRecord()
        let first = FuzzJSON.randomString(&rng), second = FuzzJSON.randomString(&rng)
        let secret: RelaySecret
        if rng.bool() {
            f.require("mode", .string("shared_secret"), &rng, odds: 8)
            f.require("secret", .string(first), &rng, odds: 8)
            secret = .sharedSecret(first)
        } else {
            f.require("mode", .string("static"), &rng, odds: 8)
            f.require("username", .string(first), &rng, odds: 8)
            f.require("password", .string(second), &rng, odds: 8)
            secret = .static(username: first, password: second)
        }
        f.noise(&rng)
        let decoded = try decode(RelaySecret.self, f.json)
        try FuzzRun.check(decoded == (f.complete ? secret : nil), "\(f.json) gave \(String(describing: decoded))")
        let again = try JSONDecoder().decode(RelaySecret.self, from: JSONEncoder().encode(secret))
        try FuzzRun.check(again == secret, "\(secret) does not survive a round trip")
        return f.json
    }

    /// A refusal's body: the protocol's `{error:{code, message}}` gives `.server`; anything else
    /// gives `.notSignedIn` for a 401 and `.http` otherwise. Every code keeps its spelling.
    static func errorBody(_ rng: inout FuzzRNG) throws -> FuzzJSON {
        let status = rng.int(in: 100...599)
        let names = DeviceHubError.Code.table.map(\.1)
        let code = rng.oneIn(3) ? FuzzJSON.randomString(&rng) : (rng.element(of: names) ?? "")
        var detail = FuzzRecord()
        detail.require("code", .string(code), &rng, odds: 6)
        let messageText = FuzzJSON.randomString(&rng)
        let message = detail.optional("message", .string(messageText), decoded: messageText, &rng)
        var body = FuzzRecord()
        body.require("error", detail.json, &rng, odds: 6)
        body.noise(&rng)
        let complete = detail.complete && body.complete
        let want: DeviceHubError = complete ? .server(status: status, code: DeviceHubError.Code(code), message: message ?? "")
            : (status == 401 ? .notSignedIn : .http(status: status))
        let got = DeviceHubError.from(status: status, data: try body.json.data())
        try FuzzRun.check(got == want, "status \(status) with \(body.json) gave \(got), not \(want)")
        try FuzzRun.check(DeviceHubError.Code(code).rawValue == code, "the code \(code) does not keep its spelling")
        return body.json
    }

    /// The record's bytes mutated, through every decoder of a hub answer: a value or an error, never a trap.
    static func mutated(_ json: FuzzJSON, _ rng: inout FuzzRNG) throws {
        let data = FuzzMutator(dictionary: FuzzJSON.tokens, maximumCount: 8_192).mutate(try json.data(), using: &rng)
        let decoder = JSONDecoder()
        _ = try? decoder.decode(HubDevice.self, from: data)
        _ = try? decoder.decode(HubRelay.self, from: data)
        _ = try? decoder.decode(HubPermission.self, from: data)
        _ = try? decoder.decode(HubSession.self, from: data)
        _ = try? decoder.decode(AuditEntry.self, from: data)
        _ = try? decoder.decode(HubMe.self, from: data)
        _ = try? decoder.decode(DeviceHubICEServer.self, from: data)
        _ = try? decoder.decode(RelaySecret.self, from: data)
        _ = try? decoder.decode(SessionTicket.self, from: data)
        _ = DeviceHubError.from(status: 400, data: data)
    }
}

/// What another device controls in the hub's crypto: its signing key, the signatures it sends, and the
/// relay blobs sealed to this device. Each gives an answer or a typed error; only the exact key,
/// signature and blob are accepted.
nonisolated struct HubCryptoCase: Sendable {
    let identity: DeviceIdentity
    let message: Data
    let signature: String
    let relayID = "r1"
    let secret = RelaySecret.static(username: "u", password: "p")
    let blob: String

    static let shared: HubCryptoCase? = try? HubCryptoCase()

    static let hexDigits = Set("0123456789abcdef")
    static let labelCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    static let nameCharacters: [Character] = FuzzJSON.alphabet + ["'", "\u{2019}", "É", "ß", "ﬁ", "Ａ", "İ", "-", "9", "Ø"]

    init() throws {
        identity = .software("2b6c9a4e-0d3b-4c5a-9e7f-112233445566")
        message = Data("GET\n/v1/me\n1800000000\n".utf8)
        signature = try identity.sign(message).base64EncodedString()
        blob = try RelaySealing.seal(.static(username: "u", password: "p"), relayID: "r1", to: identity.agreementKey)
    }

    static func check(_ rng: inout FuzzRNG) throws {
        guard let shared else {
            throw FuzzError.property("no software identity to sign and seal with", location: "HubCryptoCase")
        }
        try shared.run(&rng)
    }

    func run(_ rng: inout FuzzRNG) throws {
        let mutator = FuzzMutator(maximumEdits: 3)
        switch rng.below(5) {
        case 0:
            let key = rng.oneIn(4) ? identity.signingKey
                : String(decoding: mutator.mutate(Data(identity.signingKey.utf8), using: &rng), as: UTF8.self)
            let fingerprint = DeviceIdentity.fingerprint(signingKey: key)
            if key == identity.signingKey {
                try FuzzRun.check(fingerprint == identity.fingerprint, "the device's own key has another fingerprint")
            } else if let fingerprint {
                try FuzzRun.check(fingerprint.count == 64 && fingerprint.allSatisfy(Self.hexDigits.contains), "fingerprint \(fingerprint)")
            }
            let shown = DeviceIdentity.displayFingerprint(fingerprint ?? FuzzJSON.randomString(&rng))
            try FuzzRun.check(shown.count <= 39, "a display fingerprint of \(shown.count) characters")
        case 1:
            let changed = rng.oneIn(4) ? message : mutator.mutate(message, using: &rng)
            let valid = DeviceIdentity.verify(signature: signature, of: changed, signingKey: identity.signingKey)
            try FuzzRun.check(valid == (changed == message), "the signature verified \(valid) for a message that changed: \(changed != message)")
        case 2:
            let text = String(decoding: mutator.mutate(Data(signature.utf8), using: &rng), as: UTF8.self)
            let same = Data(base64Encoded: text) == Data(base64Encoded: signature)
            let valid = DeviceIdentity.verify(signature: text, of: message, signingKey: identity.signingKey)
            try FuzzRun.check(valid == same, "signature \(text) verified \(valid); its bytes are the signature's: \(same)")
        case 3:
            let changed = rng.oneIn(4) ? blob : String(decoding: mutator.mutate(Data(blob.utf8), using: &rng), as: UTF8.self)
            let relay = rng.oneIn(4) ? "r2" : relayID
            let exact = relay == relayID && Data(base64Encoded: changed) == Data(base64Encoded: blob)
            do {
                let opened = try RelaySealing(identity: identity).open(changed, relayID: relay)
                try FuzzRun.check(exact && opened == secret, "a changed blob or another relay's opened to \(opened)")
            } catch let error as FuzzError {
                throw error
            } catch {
                try FuzzRun.check(!exact, "the blob as sealed did not open: \(error)")
            }
        default:
            let name = rng.text(Self.nameCharacters, 48)
            let id = rng.oneIn(3) ? "" : rng.text(FuzzJSON.alphabet + ["A", "F", "3"], 20)
            let label = RelaySealing.relayLabel(deviceName: name, deviceID: id)
            try FuzzRun.check(!label.isEmpty && label.count <= 32 && label.allSatisfy(Self.labelCharacters.contains),
                              "label \(label) of \(name)")
            try FuzzRun.check(!label.hasPrefix("-") && !label.hasSuffix("-") && !label.contains("--"), "label \(label) of \(name)")
            let now = Date(timeIntervalSince1970: rng.double(in: 0...4e9))
            let secretText = FuzzJSON.randomString(&rng)
            let minted = RelaySealing.sharedSecretCredential(secret: secretText, deviceName: name, deviceID: id, now: now)
            try FuzzRun.check(minted.username == "\(Int(minted.expires.timeIntervalSince1970)):\(label)", "username \(minted.username)")
            try FuzzRun.check(Data(base64Encoded: minted.credential)?.count == 20, "credential \(minted.credential)")
            try FuzzRun.check(minted.expires > now, "credentials that expire before they are minted")
        }
    }
}
