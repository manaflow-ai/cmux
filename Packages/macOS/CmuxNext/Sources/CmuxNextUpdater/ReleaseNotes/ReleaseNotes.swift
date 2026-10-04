public import Foundation

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

    public struct Highlight: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var media: [Media]
        /// "Try it": an action id from the allow-list.
        public var action: Action?
    }

    public struct Media: Codable, Equatable, Sendable {
        public var url: URL
        /// Hex SHA-256 of the file; a mismatch drops the media.
        public var sha256: String
        public var kind: String
        public var alt: String
    }

    public struct Action: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
    }
}

/// Ed25519 signatures of published content (release notes, announcements).
nonisolated public enum ContentSignature {
    /// The `content-signing` public key (raw, base64), compiled in.
    public static let publicKey = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4="

    /// Whether `signature` (base64) signs `data` with `publicKey` (raw base64).
    public static func verify(_ data: Data, signature: String, publicKey: String = ContentSignature.publicKey) -> Bool {
        false
    }
}

/// When the what's-new card shows (pure).
nonisolated public enum WhatsNew {
    /// Once per build, after an update to it (`lastSeenBuild` older), and
    /// only when the build has human-written highlights.
    public static func shows(currentBuild: String, lastSeenBuild: String?, notes: ReleaseNotes?) -> Bool {
        false
    }
}
