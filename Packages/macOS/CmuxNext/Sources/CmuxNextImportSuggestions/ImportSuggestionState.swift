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
        self.reason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumReasonLength))
        self.requestedAt = requestedAt
        self.raisedBy = raisedBy
        self.agentSession = agentSession
        self.terminal = terminal
    }

    public static let maximumReasonLength = 280

    /// A site an agent may name: a host of letters, digits, dots and dashes
    /// with at least one dot (a URL's host is taken from it), lowercased; nil otherwise.
    /// A public suffix (`co.uk`, `github.io`) or an IP address is refused: the import keeps every
    /// cookie of the site and its subdomains, so `co.uk` would bring every UK site's sign-ins.
    public static func site(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.contains("://"), let parsed = URL(string: host)?.host { host = parsed }
        if host.hasPrefix(".") { host.removeFirst() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.count <= 253, host.contains("."), !host.hasPrefix("-"), !host.hasSuffix("."),
              !host.contains(".."), host.allSatisfy(allowed.contains), !isPublicSuffix(host) else { return nil }
        return host
    }

    /// Whether `host` (lowercased, at least two labels) is a suffix many owners register under
    /// rather than one site: an IP address, a country's second level (`co.uk`, `com.au`, `ne.jp`),
    /// or a shared hosting domain (`github.io`). A short built-in list, not the whole Public Suffix
    /// List; the consent panel still shows the person the site before anything is read.
    static func isPublicSuffix(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = labels.last else { return true }
        // An all-digit last label is an IPv4 address, never a site.
        if last.allSatisfy(\.isNumber) { return true }
        if labels.count == 2, last.count == 2, countrySecondLevels.contains(String(labels[0])) { return true }
        return sharedHostingSuffixes.contains(host)
    }

    /// Second-level labels countries register sites under (`co.uk`, `com.au`, `ac.jp`, `gov.br`).
    static let countrySecondLevels: Set<String> = [
        "ac", "co", "com", "edu", "go", "gob", "gov", "gv", "ltd", "me", "mil", "ne", "net", "nhs", "nic", "nom", "or", "org", "plc",
        "sch", "info", "biz",
    ]

    /// Domains whose every subdomain belongs to a different owner (the Public Suffix List's private section).
    static let sharedHostingSuffixes: Set<String> = [
        "amazonaws.com", "appspot.com", "azurewebsites.net", "blogspot.com", "cloudfront.net", "firebaseapp.com", "fly.dev",
        "github.io", "gitlab.io", "glitch.me", "herokuapp.com", "myshopify.com", "netlify.app", "ngrok-free.app", "ngrok.io",
        "onrender.com", "pages.dev", "repl.co", "vercel.app", "web.app", "workers.dev",
    ]
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
        guard let stored = dismissed[finding.id] else { return false }
        let then = stored.split(separator: "|", omittingEmptySubsequences: false)
        let now = finding.fingerprint.split(separator: "|", omittingEmptySubsequences: false)
        guard then.count >= 2, now.count >= 2, then.prefix(2) == now.prefix(2) else { return false }
        return Set(now.dropFirst(2)).isSubset(of: Set(then.dropFirst(2)))
    }

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
