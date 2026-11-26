public import CmuxNextBrowserImport
public import Foundation

/// A kind of thing on this Mac that cmux can bring over.
public nonisolated enum ImportSourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A browser's profiles: history, bookmarks, cookies.
    case browser
    /// Claude Code's sessions (`~/.claude/projects`).
    case claudeCode
    /// Codex's threads (`~/.codex/sessions`).
    case codex
    /// Ghostty's config, which cmux terminals already read.
    case ghostty
    /// iTerm2's profiles (colors).
    case iterm2
    /// cmux Classic's saved workspaces.
    case cmuxClassic
    /// Conductor's workspaces (`~/conductor/workspaces`), adopted in place.
    case conductor
}

/// What a scan found for one source, from folder listings and file
/// existence only: no browsing data, no Keychain item, no prompt.
public nonisolated struct ImportFinding: Codable, Sendable, Hashable, Identifiable {
    /// Whether the source can be brought over now.
    public nonisolated enum Access: String, Codable, Sendable, Hashable {
        /// One click imports it.
        case ready
        /// macOS keeps the data behind Full Disk Access (Safari).
        case needsFullDiskAccess
        /// cmux already uses it as it is (Ghostty's config).
        case inUse
    }

    /// One profile of a browser or iTerm2, by its folder (or profile) name.
    public nonisolated struct Profile: Codable, Sendable, Hashable {
        /// The profile folder ("Default", "Profile 2", "Profiles/ab12.default") or iTerm2's profile name.
        public var directoryName: String
        /// The kinds whose file is in the folder.
        public var kinds: [ImportDataKind]

        public init(directoryName: String, kinds: [ImportDataKind]) {
            self.directoryName = directoryName
            self.kinds = kinds
        }
    }

    /// `browser.<id>`, `agents.claudeCode`, `agents.codex`, `terminal.ghostty`, `terminal.iterm2`, `cmux.classic`, `agents.conductor`.
    public var id: String
    public var kind: ImportSourceKind
    /// The browser, for `.browser`.
    public var browser: ImportBrowser?
    /// The name people know it by ("Chrome", "Claude Code").
    public var name: String
    /// Browser profiles (only those not imported yet) or iTerm2 profiles.
    public var profiles: [Profile]
    /// Sessions, threads or workspaces, for the agent, Classic and Conductor sources.
    public var count: Int?
    public var access: Access

    public init(id: String, kind: ImportSourceKind, browser: ImportBrowser? = nil, name: String,
                profiles: [Profile] = [], count: Int? = 0, access: Access = .ready) {
        self.id = id
        self.kind = kind
        self.browser = browser
        self.name = name
        self.profiles = profiles
        self.count = count
        self.access = access
    }

    /// Nothing new to bring now (cmux Classic's saved session is all here already): only
    /// Settings › Import lists it, to run the import again.
    public var offersNothingNew: Bool { facts?.offersNothingNew ?? false }

    /// Every kind any profile holds: history first, as the cards name them, then `ImportDataKind` order.
    public var kinds: [ImportDataKind] { facts?.kinds ?? [] }

    /// What has to change for a dismissed card to come back: a new profile or a new kind of data,
    /// or the source appearing again; counts that grow every day are left out, so a dismiss is not
    /// undone by ordinary use (Rust's `Finding::fingerprint`).
    public var fingerprint: String { facts?.fingerprint ?? "\(id)|\(access.rawValue)" }

    private struct Facts: Decodable {
        var kinds: [ImportDataKind]
        var offersNothingNew: Bool
        var fingerprint: String
    }

    private var facts: Facts? { ImportSuggestRules.call("finding_facts", ["finding": self], as: Facts.self) }
}
