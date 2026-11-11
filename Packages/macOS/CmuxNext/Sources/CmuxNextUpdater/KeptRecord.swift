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
    /// HMAC-SHA256 (``KeptVersionStore/recordKey``) over the build, the team and the seal: a record
    /// another process wrote (a bundle changed and its seal taken again) is never trusted.
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
        mac = key.flatMap { key in
            message.map { HMAC<SHA256>.authenticationCode(for: $0, using: key).map { String(format: "%02x", $0) }.joined() }
        }
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

    /// What ``mac`` covers: the team and the seal that trust it, for this build; nil without either.
    private var message: Data? {
        guard let teamID, let seal else { return nil }
        return Data("cmux kept build\u{0}\(build)\u{0}\(teamID)\u{0}\(seal.digest)\u{0}\(seal.items)".utf8)
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
