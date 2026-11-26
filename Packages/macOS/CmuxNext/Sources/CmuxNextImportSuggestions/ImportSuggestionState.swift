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
    /// Who raised it, an `ActionOrigin` raw value (`mcp`, `cli`, `user`); nil for a request kept
    /// before this was recorded, which counts as an agent's. Import runs as this caller, so an
    /// agent's request always passes the cookie consent panel, whoever presses the button.
    public var raisedBy: String?
    /// The raising agent's chat (`caller.agent_session`), its own claim: the consent panel names it.
    public var agentSession: String?
    /// The raising terminal (`caller.terminal_id`), its own claim, when no chat named itself.
    public var terminal: String?

    public var id: String { "request.cookies.\(browser.rawValue).\(site)" }

    public init(browser: ImportBrowser, site: String, reason: String, requestedAt: Date, raisedBy: String? = nil,
                agentSession: String? = nil, terminal: String? = nil) {
        self.browser = browser
        self.site = site
        // Trimmed and cut to `maximumReasonLength` characters (Rust's `Request::new`).
        let clipped = ImportSuggestRules.call("request", ["browser": browser.rawValue, "site": site, "reason": reason, "requestedAt": requestedAt],
                                              as: Clipped.self)
        self.reason = clipped?.request.reason ?? reason
        self.requestedAt = requestedAt
        self.raisedBy = raisedBy
        self.agentSession = agentSession
        self.terminal = terminal
    }

    public static let maximumReasonLength = 280

    private struct Clipped: Decodable {
        struct Request: Decodable { var reason: String }
        var request: Request
    }

    /// A site an agent may name: a host of letters, digits, dots and dashes
    /// with at least one dot (a URL's host is taken from it), lowercased; nil otherwise.
    /// A public suffix (`co.uk`, `github.io`) or an IP address is refused: the import keeps every
    /// cookie of the site and its subdomains, so `co.uk` would bring every UK site's sign-ins
    /// (Rust's `request::site`).
    public static func site(_ text: String) -> String? {
        ImportSuggestRules.call("site", ["text": text], as: String?.self) ?? nil
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

    /// Dismissed while nothing new appeared: the same source and access, and every profile and
    /// kind it holds now was there when the person dismissed it (fewer is still dismissed).
    public func hides(_ finding: ImportFinding) -> Bool {
        ImportSuggestRules.call("state_hides", ["state": self, "finding": finding], as: Bool.self) ?? false
    }

    public mutating func dismiss(_ finding: ImportFinding) { change("dismiss", ["finding": finding]) }

    /// Shows a dismissed card again (Settings › Import's Show Again).
    public mutating func restore(_ id: String) { change("restore", ["id": id]) }

    /// Adds or refreshes a request (the same browser and site once, at most `maximumRequests`).
    public mutating func raise(_ request: ImportRequest) { change("raise", ["request": request], adding: [request]) }

    public mutating func drop(request id: String) { change("drop", ["id": id]) }

    /// Drops requests past their `requestLifetime`.
    public mutating func expire(now: Date) { change("expire", ["now": now]) }

    /// Takes Rust's state; each request keeps the one it was (its browser's registry row and exact date).
    private mutating func change(_ operation: String, _ fields: [String: any Encodable], adding: [ImportRequest] = []) {
        guard let next = ImportSuggestRules.call("state_" + operation, fields.merging(["state": self]) { kept, _ in kept }, as: Self.self) else { return }
        let known = requests + adding
        var state = next
        state.requests = next.requests.map { request in known.last { $0.id == request.id } ?? request }
        self = state
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
