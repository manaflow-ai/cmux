public import Foundation
import CryptoKit

/// The release notes published with each build (R114 changelog):
/// `<feed base>/notes/<build>.json` plus `<build>.json.sig`, an Ed25519
/// signature of the exact bytes by the `content-signing` key.
nonisolated public struct ReleaseNotes: Codable, Equatable, Sendable {
    public var version: Int
    public var build: String
    public var shortVersion: String
    public var date: String
    /// Human-written highlights (`release-notes/next/<version>.md`). A
    /// release without them shows no what's-new card (coordinator
    /// 2026-10-04); its commit-subject notes stay in the full history.
    public var highlights: [Highlight]
    /// Commit-subject lines for the full history.
    public var changes: [String]
    /// The same changes as structured items (newest first): title, author
    /// and pull request. Optional: older notes have only `changes`, and
    /// ``changeItems`` then reads the PR number from each subject.
    public var items: [ChangeItem]?
    /// The build's What's New digest (WHATS-NEW-AFTER-UPDATE W3), when
    /// release-notes.py embedded one; older notes have none.
    public var whatsNew: WhatsNewDocument?

    public init(version: Int, build: String, shortVersion: String, date: String, highlights: [Highlight], changes: [String],
                items: [ChangeItem]? = nil, whatsNew: WhatsNewDocument? = nil) {
        self.whatsNew = whatsNew
        self.version = version
        self.build = build
        self.shortVersion = shortVersion
        self.date = date
        self.highlights = highlights
        self.changes = changes
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case version, build, shortVersion, date, highlights, changes, items, whatsNew
    }

    /// A digest the app cannot read is dropped; the notes stay readable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        build = try c.decode(String.self, forKey: .build)
        shortVersion = try c.decode(String.self, forKey: .shortVersion)
        date = try c.decode(String.self, forKey: .date)
        highlights = try c.decode([Highlight].self, forKey: .highlights)
        changes = try c.decode([String].self, forKey: .changes)
        items = try c.decodeIfPresent([ChangeItem].self, forKey: .items)
        whatsNew = (try? c.decodeIfPresent(WhatsNewDocument.self, forKey: .whatsNew)) ?? nil
    }

    public struct Highlight: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var media: [Media]
        /// "Try it": an action id from the allow-list.
        public var action: Action?

        public init(id: String, title: String, body: String, media: [Media], action: Action?) {
            self.id = id
            self.title = title
            self.body = body
            self.media = media
            self.action = action
        }
    }

    public struct Media: Codable, Equatable, Sendable {
        public var url: URL
        /// Hex SHA-256 of the file; a mismatch drops the media.
        public var sha256: String
        public var kind: String
        public var alt: String

        public init(url: URL, sha256: String, kind: String, alt: String) {
            self.url = url
            self.sha256 = sha256
            self.kind = kind
            self.alt = alt
        }
    }

    public struct Action: Codable, Equatable, Sendable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }
}

/// Ed25519 signatures of published content (release notes, announcements).
nonisolated public struct ContentSignature {
    public init() {}
    /// The `content-signing` public key (raw, base64), compiled in.
    public static let publicKey = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4="

    /// Whether `signature` (base64) signs `data` with `publicKey` (raw base64).
    public static func verify(_ data: Data, signature: String, publicKey: String = ContentSignature.publicKey) -> Bool {
        guard let signatureBytes = Data(base64Encoded: signature), let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { return false }
        return key.isValidSignature(signatureBytes, for: data)
    }
}
