public import Foundation

/// One release's What's New page (decision WHATS-NEW-AFTER-UPDATE W2):
/// `whats-new/<version>.json`, schema `schemas/whats-new/v1.schema.json`.
/// The release gate (`scripts/whats-new/validate.py`) checks wording,
/// languages and media; the app only needs the shape, and drops a document
/// it cannot read instead of failing.
nonisolated public struct WhatsNewDocument: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var version: String
    public var channel: Channel
    public var date: String
    public var headline: WhatsNewText
    public var entries: [Entry]
    /// Where the app read it (not encoded): bundled documents were reviewed
    /// with the app; feed documents only run allow-listed try-it actions.
    public var origin: Origin = .bundled

    public var id: String { version }

    public enum Channel: String, Codable, Sendable {
        case stable, rc, nightly
    }

    public enum Origin: Sendable, Equatable {
        case bundled
        case feed
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case new, improved, fixed, security
    }

    public enum Audience: String, Codable, Sendable {
        case all, teams, enterprise
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var category: Category
        public var title: WhatsNewText
        public var summary: WhatsNewText
        public var media: Media?
        public var tryIt: TryIt?
        public var docs: URL?
        public var platforms: [String]
        public var audience: Audience

        public init(id: String, category: Category, title: WhatsNewText, summary: WhatsNewText, media: Media? = nil,
                    tryIt: TryIt? = nil, docs: URL? = nil, platforms: [String] = ["macos"], audience: Audience = .all) {
            self.id = id
            self.category = category
            self.title = title
            self.summary = summary
            self.media = media
            self.tryIt = tryIt
            self.docs = docs
            self.platforms = platforms
            self.audience = audience
        }

        /// Whether this Mac app has anything to show for the entry.
        public var isForMac: Bool { platforms.contains("macos") || platforms.contains("cli") }
    }

    public struct Media: Codable, Equatable, Sendable {
        public var kind: String
        /// Paths relative to the whats-new directory (`media/<version>/<file>`).
        public var light: String
        public var dark: String
        public var alt: WhatsNewText

        public init(kind: String, light: String, dark: String, alt: WhatsNewText) {
            self.kind = kind
            self.light = light
            self.dark = dark
            self.alt = alt
        }

        public var isVideo: Bool { kind == "video" }

        /// A path is safe when it stays under `media/`.
        static func isSafe(_ path: String) -> Bool {
            path.hasPrefix("media/") && !path.split(separator: "/").contains("..") && !path.contains("\\")
        }
    }

    /// Exactly one of a registry action id or a `cmux://` deeplink.
    public struct TryIt: Codable, Equatable, Sendable {
        public var action: String?
        public var deeplink: String?

        public init(action: String? = nil, deeplink: String? = nil) {
            self.action = action
            self.deeplink = deeplink
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, version, channel, date, headline, entries
    }

    public init(version: String, channel: Channel, date: String, headline: WhatsNewText, entries: [Entry], origin: Origin = .bundled) {
        schemaVersion = 1
        self.version = version
        self.channel = channel
        self.date = date
        self.headline = headline
        self.entries = entries
        self.origin = origin
    }

    /// The parsed version; nil for a version the app cannot order.
    public var parsedVersion: WhatsNewVersion? { WhatsNewVersion(version) }

    /// A document the app reads: schema 1, an orderable version, entries
    /// for this Mac, safe media paths. Entries for other platforms and
    /// media outside `media/` are dropped, not the whole document.
    public static func decode(_ data: Data, origin: Origin) -> WhatsNewDocument? {
        guard var document = try? JSONDecoder().decode(WhatsNewDocument.self, from: data),
              document.schemaVersion == 1, document.parsedVersion != nil else { return nil }
        document.origin = origin
        document.entries = document.entries.filter(\.isForMac).map { entry in
            var entry = entry
            if let media = entry.media, !(Media.isSafe(media.light) && Media.isSafe(media.dark)) { entry.media = nil }
            if let docs = entry.docs, docs.scheme != "https" { entry.docs = nil }
            if let link = entry.tryIt?.deeplink, !link.hasPrefix("cmux://") { entry.tryIt = nil }
            return entry
        }
        return document
    }
}

/// Text in every language the document carries (Apple language codes).
nonisolated public struct WhatsNewText: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    public var values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public init(stringLiteral value: String) {
        values = ["en": value]
    }

    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: String].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// The text for the first of `languages` the document has (exact code,
    /// then the code without its region or script), else English.
    public func resolved(for languages: [String] = Locale.preferredLanguages) -> String {
        for language in languages {
            for candidate in Self.candidates(language) {
                if let text = values[candidate], !text.isEmpty { return text }
            }
        }
        return values["en"] ?? values.values.sorted().first ?? ""
    }

    /// "zh-Hant-TW" -> zh-Hant-TW, zh-Hant, zh; "pt-PT" -> pt-PT, pt, pt-BR;
    /// "nb-NO"/"no" -> nb.
    static func candidates(_ language: String) -> [String] {
        let parts = language.split(separator: "-").map(String.init)
        var out: [String] = []
        for count in stride(from: parts.count, through: 1, by: -1) {
            out.append(parts.prefix(count).joined(separator: "-"))
        }
        switch parts.first {
        case "pt": out.append("pt-BR")
        case "no", "nn": out.append("nb")
        case "zh": out.append(parts.contains("Hant") || parts.contains("TW") || parts.contains("HK") ? "zh-Hant" : "zh-Hans")
        default: break
        }
        return out
    }
}
