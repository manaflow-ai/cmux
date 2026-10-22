public import CmuxNextBrowserImport
public import Foundation

/// One cookie import request in the audit ledger (``CookieImportLedger``): who asked, why, from
/// which browser into which cmux profile, the person's answer and what was written. It holds the
/// written cookies' names, domains and paths (``ImportedCookieIdentity``) so Remove can take them
/// back out, and never a cookie value.
public nonisolated struct CookieImportRecord: Sendable, Equatable, Codable, Identifiable {
    /// How the request ended.
    public nonisolated enum Outcome: String, Sendable, Codable {
        /// Cookies were written into the target profile.
        case imported
        /// The person pressed Deny (or closed the card).
        case denied
        /// Nobody answered within the card's time limit.
        case timedOut
        /// The source profile had no cookie for the named sites.
        case nothingMatched
        /// The read or the write failed; ``CookieImportRecord/failure`` says why.
        case failed
    }

    /// Who asked, as the card named them.
    public nonisolated struct Requester: Sendable, Equatable, Codable {
        /// `agentChat`, `homeChief`, `terminal`, `unknown`, or `person` (a person's own run).
        public var kind: String
        /// The chat's, Chief's or terminal's name; empty for a person or an unknown program.
        public var name: String

        /// Creates a requester entry.
        public init(kind: String, name: String) {
            self.kind = kind
            self.name = name
        }
    }

    /// The record's id (a UUID string), what `Remove` names.
    public var id: String
    /// When the request was made.
    public var date: Date
    /// Who asked.
    public var requester: Requester
    /// The agent's reason as it gave it; empty for a person's run.
    public var reason: String
    /// The source as shown ("Google Chrome · Work").
    public var source: String
    /// The cmux browser profile's id and name the cookies went (or would go) into.
    public var targetProfileID: String
    public var targetProfileName: String
    /// The `--domain` sites asked for; empty asked for every cookie of the profile.
    public var requestedSites: [String]
    /// How it ended.
    public var outcome: Outcome
    /// A failure's text (no path, no value), nil otherwise.
    public var failure: String?
    /// Counts of the import, nil when nothing was read.
    public var report: CookieImportReport?
    /// The cookies handed to the target profile (no values).
    public var cookies: [ImportedCookieIdentity]
    /// When the person removed this import's cookies again, nil while they are in.
    public var removedAt: Date?

    /// Creates a record.
    public init(id: String = UUID().uuidString, date: Date, requester: Requester, reason: String, source: String,
                targetProfileID: String, targetProfileName: String, requestedSites: [String], outcome: Outcome,
                failure: String? = nil, report: CookieImportReport? = nil, cookies: [ImportedCookieIdentity] = [], removedAt: Date? = nil) {
        self.id = id
        self.date = date
        self.requester = requester
        self.reason = reason
        self.source = source
        self.targetProfileID = targetProfileID
        self.targetProfileName = targetProfileName
        self.requestedSites = requestedSites
        self.outcome = outcome
        self.failure = failure
        self.report = report
        self.cookies = cookies
        self.removedAt = removedAt
    }

    /// One site of an import and how many of its cookies came in.
    public nonisolated struct Site: Sendable, Equatable {
        /// The host without a leading dot (`github.com`).
        public var host: String
        /// How many cookies of that host were written.
        public var count: Int
    }

    /// The imported cookies by host, the most cookies first, then by name.
    public var sites: [Site] {
        Dictionary(grouping: cookies, by: \.host).map { Site(host: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.host < $1.host }
    }

    /// Whether Remove can still act on it: cookies came in and were not removed yet.
    public var canRemove: Bool { outcome == .imported && removedAt == nil && !cookies.isEmpty }
}
