public import Foundation

/// What a card's button does (`import.card {id, action}`).
public nonisolated enum ImportCardAction: String, Codable, Sendable, CaseIterable, Hashable {
    /// Import (or Show Chats for the agent sources).
    case start
    /// Go on with a paused job.
    case resume
    /// Run a failed job again.
    case retry
    /// Not Now: the card stays gone until something new appears.
    case dismiss
    /// Settings › Import's Show Again for a dismissed card.
    case restore
    /// The full Import from Browser window for this browser (passwords, other profiles, files).
    case more
    /// The thing the import made or uses (All chats, the theme, Ghostty's config, Full Disk Access).
    case open
    /// Done: put a finished card away.
    case hide
}

extension ImportCardAction {
    /// Start, Resume and Try Again read another app's data, so only the person runs them.
    public var startsWork: Bool { self == .start || self == .resume || self == .retry }
}

extension ImportSourceKind {
    /// Starting it reads another app's data into cmux (a browser's history, bookmarks and cookies;
    /// iTerm2's colors written as a theme), so a start that is not the person's own click in this
    /// app (a page's button) asks the person natively first. The others only open something of
    /// cmux's, or ask on their own (Classic's preview).
    nonisolated public var startReadsAnotherApp: Bool { self == .browser || self == .iterm2 }
}

/// One card as Settings › Import draws it: every text is already in the person's language.
public nonisolated struct ImportCard: Codable, Sendable, Equatable, Identifiable {
    public nonisolated enum State: String, Codable, Sendable {
        case ready, running, paused, done, failed
        /// Nothing to import: it is already in use, or it waits for a macOS setting.
        case info
    }

    public nonisolated struct Button: Codable, Sendable, Equatable {
        public var action: ImportCardAction
        public var title: String

        public init(_ action: ImportCardAction, _ title: String) {
            self.action = action
            self.title = title
        }
    }

    public var id: String
    public var kind: ImportSourceKind
    /// The source app's bundle id, for its icon (the surface draws the app's own icon).
    public var app: String?
    /// "Chrome", or a Chief request's "Import Chrome cookies for github.com".
    public var title: String
    /// What was found: "3 profiles · history, cookies, bookmarks", "412 sessions".
    public var facts: String
    /// What the import gives: "Sites you're signed into stay signed in here…".
    public var benefit: String
    /// The agent's words, for a Chief request.
    public var reason: String?
    /// Who raised it ("Chief"), for a request.
    public var requestedBy: String?
    public var state: State
    /// 0...1 while running or paused.
    public var progress: Double?
    /// "Importing profile 2 of 3…", "Done: 4,812 pages, 312 bookmarks".
    public var status: String?
    public var primary: Button?
    public var secondary: [Button]
    /// Settings › Import lists dismissed cards too, dimmed with Show Again.
    public var dismissed: Bool

    public init(id: String, kind: ImportSourceKind, app: String?, title: String, facts: String, benefit: String,
                reason: String? = nil, requestedBy: String? = nil, state: State, progress: Double? = nil, status: String? = nil,
                primary: Button?, secondary: [Button], dismissed: Bool = false) {
        self.id = id
        self.kind = kind
        self.app = app
        self.title = title
        self.facts = facts
        self.benefit = benefit
        self.reason = reason
        self.requestedBy = requestedBy
        self.state = state
        self.progress = progress
        self.status = status
        self.primary = primary
        self.secondary = secondary
        self.dismissed = dismissed
    }
}

/// The cards a surface shows, with their header.
public nonisolated struct ImportCardList: Codable, Sendable, Equatable {
    public var title: String
    public var cards: [ImportCard]

    public init(title: String, cards: [ImportCard]) {
        self.title = title
        self.cards = cards
    }

    public static let empty = ImportCardList(title: "", cards: [])
}
