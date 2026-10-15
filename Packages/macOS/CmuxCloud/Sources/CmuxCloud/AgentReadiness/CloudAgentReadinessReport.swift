import Foundation

/// What one agent's next launch on a machine would use, as the readiness script
/// reported it. Names, fixed words, a host, and an HTTP status: never a value.
public struct CloudAgentReadinessEntry: Hashable, Sendable {
    /// Where the launch's credential comes from.
    public enum Source: String, Hashable, Sendable {
        /// A provider key in the machine env (Cloud Secrets or `vm env set`).
        case key
        /// The agent's own sign-in on the machine (`/login`, `codex login`, …).
        case login
        /// cmux model routing: the team's accounts through the machine's edge.
        case routing
        /// A provider the user configured in the agent's own config file.
        case config
        /// Nothing the launch could authenticate with.
        case none
    }

    /// Where the launch sends that credential.
    public enum Endpoint: String, Hashable, Sendable {
        /// The key's own provider (its public API host).
        case provider
        /// cmux model routing.
        case cmux
        /// An endpoint the user set (`*_BASE_URL`, a codex provider of theirs).
        case custom
        /// A key whose provider endpoint Cloud Secrets' routing guard has not
        /// added yet, so the model plane's endpoint could outrank it.
        case unrouted
        case none
    }

    /// The live auth probe's answer.
    public enum Probe: Hashable, Sendable {
        case notRun
        case status(Int)
        case unreachable
        /// The value could not be carried to curl verbatim, so it was not sent.
        case skipped
        /// No probe exists for that key's provider.
        case unsupported
    }

    public let agent: CloudAgentReadinessAgent
    public let installed: Bool
    public let version: String?
    public let source: Source
    /// The env name the credential is read from, when one is.
    public let keyName: String?
    /// The image's sign-in mode (`team`/`own`) for claude, codex, and opencode.
    public let mode: String?
    /// Why that mode applies (agent-auth.sh's reasons: `chosen`, `login`, `team-account`, …).
    public let reason: String?
    public let endpoint: Endpoint
    public let host: String?
    public let probe: Probe
    /// For `gh`: whether git's GitHub credential helper is configured.
    public let gitCredentialHelper: Bool?

    public init(
        agent: CloudAgentReadinessAgent,
        installed: Bool,
        version: String? = nil,
        source: Source,
        keyName: String? = nil,
        mode: String? = nil,
        reason: String? = nil,
        endpoint: Endpoint,
        host: String? = nil,
        probe: Probe = .notRun,
        gitCredentialHelper: Bool? = nil
    ) {
        self.agent = agent
        self.installed = installed
        self.version = version
        self.source = source
        self.keyName = keyName
        self.mode = mode
        self.reason = reason
        self.endpoint = endpoint
        self.host = host
        self.probe = probe
        self.gitCredentialHelper = gitCredentialHelper
    }

    /// One `agent=… installed=… …` line, or nil when it is not one. Every field is
    /// checked against the shape the script can print, so a stray line never
    /// becomes text the CLI or the app shows.
    init?(line: String) {
        var fields: [String: String] = [:]
        for pair in line.split(separator: " ") {
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        func value(_ name: String, where valid: (String) -> Bool = { _ in true }) -> String? {
            guard let raw = fields[name], raw != "-", !raw.isEmpty, valid(raw) else { return nil }
            return raw
        }
        guard let agent = value("agent").flatMap(CloudAgentReadinessAgent.init(rawValue:)),
              let source = value("source").flatMap(Source.init(rawValue:)),
              let endpoint = value("endpoint").flatMap(Endpoint.init(rawValue:)) else { return nil }
        self.agent = agent
        self.installed = value("installed") == "1"
        self.version = value("version") { Self.isToken($0, allowed: Self.versionCharacters) }
        self.source = source
        self.keyName = value("key", where: Self.isVariableName)
        let words = Self.wordCharacters
        self.mode = value("mode") { $0 != "unknown" && Self.isToken($0, allowed: words) }
        self.reason = value("reason") { $0 != "unknown" && Self.isToken($0, allowed: words) }
        self.endpoint = endpoint
        self.host = value("host") { Self.isToken($0, allowed: Self.hostCharacters) }
        switch value("probe") {
        case nil: self.probe = .notRun
        case "unreachable": self.probe = .unreachable
        case "skipped": self.probe = .skipped
        case "unsupported": self.probe = .unsupported
        case let raw?:
            if let code = Int(raw), (100...599).contains(code) {
                self.probe = .status(code)
            } else {
                self.probe = .notRun
            }
        }
        switch value("helper") {
        case "1": self.gitCredentialHelper = true
        case "0": self.gitCredentialHelper = false
        default: self.gitCredentialHelper = nil
        }
    }

    private static let versionCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-_")
    private static let wordCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz-")
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")

    private static func isToken(_ text: String, allowed: CharacterSet) -> Bool {
        text.count <= 64 && text.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `^[A-Z_][A-Z0-9_]*$`: the names the script reads keys from.
    static func isVariableName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, text.count <= 64 else { return false }
        let upper = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let rest = upper.union(CharacterSet(charactersIn: "0123456789"))
        return upper.contains(first) && text.unicodeScalars.allSatisfy(rest.contains)
    }
}

/// The readiness script's whole answer for one machine.
public struct CloudAgentReadinessReport: Hashable, Sendable {
    public let entries: [CloudAgentReadinessEntry]
    /// The machine has cmux model routing (`/etc/cmux/model-plane.env`).
    public let hasModelRouting: Bool
    /// The machine's image resolves per-agent sign-in modes (`/etc/cmux/agent-auth.sh`).
    public let hasSignInModes: Bool

    public init(entries: [CloudAgentReadinessEntry], hasModelRouting: Bool, hasSignInModes: Bool) {
        self.entries = entries
        self.hasModelRouting = hasModelRouting
        self.hasSignInModes = hasSignInModes
    }

    static let header = "cmux-agent-readiness v1"
    static let trailer = "cmux-agent-readiness end"

    /// The script's stdout, or nil when it is not a complete answer (an exec that
    /// failed, timed out, or ran on a machine that could not run the script).
    public init?(output: String) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix(Self.header) }),
              let end = lines.lastIndex(of: Self.trailer), start < end else { return nil }
        let headerFields = lines[start].split(separator: " ")
        hasModelRouting = headerFields.contains("plane=1")
        hasSignInModes = headerFields.contains("auth=1")
        var seen = Set<CloudAgentReadinessAgent>()
        var parsed: [CloudAgentReadinessEntry] = []
        for line in lines[(start + 1)..<end] {
            guard let entry = CloudAgentReadinessEntry(line: line), seen.insert(entry.agent).inserted else { continue }
            parsed.append(entry)
        }
        entries = parsed
    }
}
