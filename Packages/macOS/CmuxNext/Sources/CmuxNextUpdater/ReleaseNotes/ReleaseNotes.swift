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

    public init(version: Int, build: String, shortVersion: String, date: String, highlights: [Highlight], changes: [String]) {
        self.version = version
        self.build = build
        self.shortVersion = shortVersion
        self.date = date
        self.highlights = highlights
        self.changes = changes
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

/// When the what's-new card shows (pure).
nonisolated public struct WhatsNew {
    public init() {}
    /// Once per build, after an update to it (`lastSeenBuild` older), and
    /// only when the build has human-written highlights.
    public static func shows(currentBuild: String, lastSeenBuild: String?, notes: ReleaseNotes?) -> Bool {
        guard let lastSeenBuild, let notes, notes.build == currentBuild, !notes.highlights.isEmpty else { return false }
        return currentBuild.compare(lastSeenBuild, options: .numeric) == .orderedDescending
    }
}
