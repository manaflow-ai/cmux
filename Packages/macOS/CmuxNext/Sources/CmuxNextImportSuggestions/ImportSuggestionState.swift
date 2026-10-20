public import CmuxNextBrowserImport
public import Foundation

/// A card the Chief (or another agent) raised because it noticed a gap: a
/// browser pane hit a sign-in page for a site another browser is signed
/// into, so the card offers that site's cookies. Nothing is read until the
/// person clicks Import on the card.
public nonisolated struct ImportRequest: Codable, Sendable, Hashable, Identifiable {
    public var browser: ImportBrowser
    /// The site's host (`github.com`), already checked by ``site(_:)``.
    public var site: String
    /// What the agent said it needs, shown on the card.
    public var reason: String
    public var requestedAt: Date

    public var id: String { "request.cookies.\(browser.rawValue).\(site)" }

    public init(browser: ImportBrowser, site: String, reason: String, requestedAt: Date) {
        self.browser = browser
        self.site = site
        self.reason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumReasonLength))
        self.requestedAt = requestedAt
    }

    public static let maximumReasonLength = 280

    /// A site an agent may name: a host of letters, digits, dots and dashes
    /// with at least one dot (a URL's host is taken from it), lowercased; nil otherwise.
    public static func site(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.contains("://"), let parsed = URL(string: host)?.host { host = parsed }
        if host.hasPrefix(".") { host.removeFirst() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.count <= 253, host.contains("."), !host.hasPrefix("-"), !host.hasSuffix("."),
              !host.contains(".."), host.allSatisfy(allowed.contains) else { return nil }
        return host
    }
}

/// What the person told the cards, kept per Mac: dismissed cards (with the
/// fingerprint they had, so a card comes back only when something new
/// appears) and the open Chief requests.
public nonisolated struct ImportSuggestionState: Codable, Sendable, Equatable {
    /// Card id to the fingerprint it had when dismissed.
    public var dismissed: [String: String] = [:]
    public var requests: [ImportRequest] = []

    /// The most open requests kept; an older one goes when a new one comes.
    public static let maximumRequests = 6
    /// A request nobody answered goes after a day.
    public static let requestLifetime: TimeInterval = 24 * 3600

    public init() {}

    public func hides(_ finding: ImportFinding) -> Bool { dismissed[finding.id] == finding.fingerprint }

    public mutating func dismiss(_ finding: ImportFinding) { dismissed[finding.id] = finding.fingerprint }

    /// Shows a dismissed card again (Settings › Import's Show Again).
    public mutating func restore(_ id: String) { dismissed[id] = nil }

    /// Adds or refreshes a request (the same browser and site once).
    public mutating func raise(_ request: ImportRequest) {
        requests.removeAll { $0.id == request.id }
        requests.insert(request, at: 0)
        if requests.count > Self.maximumRequests { requests.removeLast(requests.count - Self.maximumRequests) }
    }

    public mutating func drop(request id: String) { requests.removeAll { $0.id == id } }

    /// Drops requests past their lifetime.
    public mutating func expire(now: Date) {
        requests.removeAll { now.timeIntervalSince($0.requestedAt) > Self.requestLifetime }
    }

    public static let defaultsKey = "importSuggestions.state"

    public static func load(from defaults: UserDefaults) -> ImportSuggestionState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder.importJobs.decode(ImportSuggestionState.self, from: data) else { return ImportSuggestionState() }
        return state
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder.importJobs.encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
