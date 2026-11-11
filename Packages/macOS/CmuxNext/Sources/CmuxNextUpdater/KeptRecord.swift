import CmuxNextCompat
public import CryptoKit
public import Foundation

/// What is known about a kept build (`kept.json` beside it).
nonisolated public struct KeptRecord: Codable, Equatable, Sendable {
    public var build: String
    /// When it was kept (the update that left it, or the download that kept it).
    public var keptAt: Date?
    /// When the build was made, `YYYY-MM-DD` (the feed's notes); nil when not known.
    public var date: String?
    /// The team a full check of every file found (sealed by ``seal``); nil until checked.
    public var teamID: String?
    /// The store schemas it reads (its Info.plist, else its CLI), read when it was kept.
    public var storeSchemas: [String: Int]?
    /// The bundle as the full check read it; nil: not checked yet (``KeptVersionStore/sealPending()``).
    var seal: KeptSeal?
    /// Whether its code has run once since it was kept (``KeptWarmup``); nil: not yet.
    var warmed: Bool?
    /// HMAC-SHA256 (``KeptVersionStore/recordKey``) over the build, the team, the seal and the store
    /// schemas: a record another process wrote (a bundle changed and its seal taken again, or the
    /// schemas raised so an old build is let at newer stores) is never trusted.
    var mac: String?
    /// The running build whose launch could not check every file of it (``KeptVersionStore/sealPending(runningBuild:)``).
    var sealFailedBy: String?
    /// The running build whose launch could not run its code (``KeptWarmup``).
    var warmFailedBy: String?

    public init(build: String, date: String? = nil, teamID: String? = nil, storeSchemas: [String: Int]? = nil) {
        self.build = build
        self.date = date
        self.teamID = teamID
        self.storeSchemas = storeSchemas
    }

    /// Seals the kept copy `bundle` by `check`: a full check now, the caller's check of a source
    /// nothing can change, or nothing yet (no team: a team without a seal is never trusted).
    /// `key` signs the result (no key: no MAC, so the seal is never trusted).
    mutating func seal(_ bundle: URL, check: KeptVersionStore.Check, fullCheck: (URL) -> String?, key: SymmetricKey?) {
        switch check {
        case .full:
            let verified = KeptSeal.verified(bundle, fullCheck: fullCheck)
            teamID = verified?.team
            seal = verified?.seal
        case .checkedSource:
            seal = teamID == nil ? nil : KeptSeal(bundle: bundle)
        case .later:
            teamID = nil
            seal = nil
        }
        sign(key: key)
    }

    /// Signs the record as it stands with `key` (no key, or no sealed team: no MAC). Only for a record
    /// this app just wrote or one ``isAuthentic(key:)`` vouched for before the caller changed it:
    /// signing a record read from disk unchecked would vouch for what another process wrote.
    mutating func sign(key: SymmetricKey?) {
        mac = key.flatMap { key in
            message.map { HMAC<SHA256>.authenticationCode(for: $0, using: key).map { String(format: "%02x", $0) }.joined() }
        }
    }

    /// ``storeSchemas`` when ``isAuthentic(key:)`` vouches for them, else nil: the schemas let a
    /// rollback skip the kept build's own CLI, so only ones this app wrote count (cmux#41013 review).
    func trustedStoreSchemas(key: SymmetricKey?) -> [String: Int]? {
        isAuthentic(key: key) ? storeSchemas : nil
    }

    /// Whether ``mac`` is this record's under `key` (compared in constant time).
    func isAuthentic(key: SymmetricKey?) -> Bool {
        guard let key, let mac, mac.count == 64, let message else { return false }
        var code = [UInt8]()
        var index = mac.startIndex
        while index < mac.endIndex {
            let next = mac.index(index, offsetBy: 2)
            guard let byte = UInt8(mac[index..<next], radix: 16) else { return false }
            code.append(byte)
            index = next
        }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: message, using: key)
    }

    /// What ``mac`` covers: the team and the seal that trust it and the store schemas it vouches for,
    /// for this build; nil without a team or a seal.
    private var message: Data? {
        guard let teamID, let seal else { return nil }
        let schemas = storeSchemas.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? "-"
        return Data("cmux kept build v2\u{0}\(build)\u{0}\(teamID)\u{0}\(seal.digest)\u{0}\(seal.items)\u{0}\(schemas)".utf8)
    }

    static func read(from file: URL) -> KeptRecord? {
        guard let data = try? Data(blockingContentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeptRecord.self, from: data)
    }

    func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).blockingWrite(to: file, options: .atomic)
    }
}
