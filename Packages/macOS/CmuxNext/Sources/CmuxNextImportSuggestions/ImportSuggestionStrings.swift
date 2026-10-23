public import CmuxNextBrowserImport
import Foundation

/// The cards' words (table `ImportSuggestions`).
public nonisolated struct ImportSuggestionStrings: Sendable {
    public init() {}

    public static var settingsTitle: String { String(localized: "importSuggestions.settings.title", defaultValue: "Found on This Mac", table: "ImportSuggestions", bundle: .module) }

    // MARK: Facts

    static func profiles(_ count: Int) -> String {
        String(localized: "importSuggestions.facts.profiles", defaultValue: "\(count) profiles", table: "ImportSuggestions", bundle: .module)
    }
    static func sessions(_ count: Int) -> String {
        String(localized: "importSuggestions.facts.sessions", defaultValue: "\(count) sessions", table: "ImportSuggestions", bundle: .module)
    }
    static func threads(_ count: Int) -> String {
        String(localized: "importSuggestions.facts.threads", defaultValue: "\(count) threads", table: "ImportSuggestions", bundle: .module)
    }
    static func workspaces(_ count: Int) -> String {
        String(localized: "importSuggestions.facts.workspaces", defaultValue: "\(count) saved workspaces", table: "ImportSuggestions", bundle: .module)
    }
    /// cmux Classic's saved session, all of it here already.
    static var classicAllHere: String {
        String(localized: "importSuggestions.facts.classicAllHere", defaultValue: "Every saved workspace is here", table: "ImportSuggestions", bundle: .module)
    }
    static var needsFullDiskAccess: String { String(localized: "importSuggestions.facts.fullDiskAccess", defaultValue: "Needs Full Disk Access", table: "ImportSuggestions", bundle: .module) }
    static var inUse: String { String(localized: "importSuggestions.facts.inUse", defaultValue: "Already in use", table: "ImportSuggestions", bundle: .module) }

    static func kind(_ kind: ImportDataKind) -> String {
        switch kind {
        case .history: String(localized: "importSuggestions.kind.history", defaultValue: "history", table: "ImportSuggestions", bundle: .module)
        case .bookmarks: String(localized: "importSuggestions.kind.bookmarks", defaultValue: "bookmarks", table: "ImportSuggestions", bundle: .module)
        case .cookies: String(localized: "importSuggestions.kind.cookies", defaultValue: "cookies", table: "ImportSuggestions", bundle: .module)
        case .passwords: String(localized: "importSuggestions.kind.passwords", defaultValue: "passwords", table: "ImportSuggestions", bundle: .module)
        case .openTabs, .extensions, .searchEngines: ""
        }
    }

    // MARK: What you get

    static func browserSignedIn(_ browser: String) -> String {
        String(localized: "importSuggestions.benefit.browserSignedIn",
               defaultValue: "Sites you're signed into in \(browser) stay signed in here, and your history fills the address bar.",
               table: "ImportSuggestions", bundle: .module)
    }
    static func browserHistory(_ browser: String) -> String {
        String(localized: "importSuggestions.benefit.browserHistory", defaultValue: "Your \(browser) history and bookmarks fill cmux's address bar.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var safariAccess: String {
        String(localized: "importSuggestions.benefit.safariAccess",
               defaultValue: "Turn on Full Disk Access for cmux in System Settings to bring Safari's history and bookmarks.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var claudeCode: String {
        String(localized: "importSuggestions.benefit.claudeCode",
               defaultValue: "Your Claude Code history becomes searchable chats. Open one to pick up where you left off.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var codex: String {
        String(localized: "importSuggestions.benefit.codex",
               defaultValue: "Your Codex threads become searchable chats. Open one to pick up where you left off.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var classic: String {
        String(localized: "importSuggestions.benefit.classic", defaultValue: "Your Classic workspaces open here, with their tabs, folders and agent chats.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var classicAgain: String {
        String(localized: "importSuggestions.benefit.classicAgain",
               defaultValue: "Import again to reopen Classic workspaces you closed here. Ones still open aren't duplicated.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var iterm2: String {
        String(localized: "importSuggestions.benefit.iterm2", defaultValue: "Your iTerm2 colors become a cmux terminal theme you can pick in Appearance.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var ghostty: String {
        String(localized: "importSuggestions.benefit.ghostty", defaultValue: "cmux terminals already use your Ghostty config: fonts, theme and keys.",
               table: "ImportSuggestions", bundle: .module)
    }
    static func request(site: String) -> String {
        String(localized: "importSuggestions.benefit.request",
               defaultValue: "You stay signed in to \(site) in cmux's browser. Only that site's cookies come over.",
               table: "ImportSuggestions", bundle: .module)
    }
    public static func requestTitle(browser: String, site: String) -> String {
        String(localized: "importSuggestions.request.title", defaultValue: "Import \(browser) cookies for \(site)",
               table: "ImportSuggestions", bundle: .module)
    }
    static func requestedBy(_ name: String) -> String {
        String(localized: "importSuggestions.request.by", defaultValue: "Asked by \(name)", table: "ImportSuggestions", bundle: .module)
    }
    static var chief: String { String(localized: "importSuggestions.request.chief", defaultValue: "Chief", table: "ImportSuggestions", bundle: .module) }

    // MARK: Buttons

    static var importButton: String { String(localized: "importSuggestions.button.import", defaultValue: "Import", table: "ImportSuggestions", bundle: .module) }
    static var showChats: String { String(localized: "importSuggestions.button.showChats", defaultValue: "Show Chats", table: "ImportSuggestions", bundle: .module) }
    static var importWorkspaces: String { String(localized: "importSuggestions.button.importWorkspaces", defaultValue: "Import Workspaces", table: "ImportSuggestions", bundle: .module) }
    static var importAgain: String { String(localized: "importSuggestions.button.importAgain", defaultValue: "Import Again", table: "ImportSuggestions", bundle: .module) }
    static var importColors: String { String(localized: "importSuggestions.button.importColors", defaultValue: "Import Colors", table: "ImportSuggestions", bundle: .module) }
    static var notNow: String { String(localized: "importSuggestions.button.notNow", defaultValue: "Not Now", table: "ImportSuggestions", bundle: .module) }
    static var resume: String { String(localized: "importSuggestions.button.resume", defaultValue: "Resume", table: "ImportSuggestions", bundle: .module) }
    static var retry: String { String(localized: "importSuggestions.button.retry", defaultValue: "Try Again", table: "ImportSuggestions", bundle: .module) }
    static var more: String { String(localized: "importSuggestions.button.more", defaultValue: "More Options…", table: "ImportSuggestions", bundle: .module) }
    static var showAgain: String { String(localized: "importSuggestions.button.showAgain", defaultValue: "Show Again", table: "ImportSuggestions", bundle: .module) }
    static var openConfig: String { String(localized: "importSuggestions.button.openConfig", defaultValue: "Open Config", table: "ImportSuggestions", bundle: .module) }
    static var openSystemSettings: String { String(localized: "importSuggestions.button.openSystemSettings", defaultValue: "Open System Settings", table: "ImportSuggestions", bundle: .module) }
    static var openAppearance: String { String(localized: "importSuggestions.button.openAppearance", defaultValue: "Open Appearance", table: "ImportSuggestions", bundle: .module) }
    static var done: String { String(localized: "importSuggestions.button.done", defaultValue: "Done", table: "ImportSuggestions", bundle: .module) }

    // MARK: Status

    static var running: String { String(localized: "importSuggestions.status.running", defaultValue: "Importing…", table: "ImportSuggestions", bundle: .module) }
    static var interrupted: String { String(localized: "importSuggestions.status.interrupted", defaultValue: "Paused when cmux quit. Resume to finish.", table: "ImportSuggestions", bundle: .module) }
    static var needsPerson: String {
        String(localized: "importSuggestions.status.needsPerson", defaultValue: "Paused. Resume to finish; macOS may ask for your password.",
               table: "ImportSuggestions", bundle: .module)
    }
    static var declined: String { String(localized: "importSuggestions.status.declined", defaultValue: "Stopped: access wasn't allowed.", table: "ImportSuggestions", bundle: .module) }
    static var sourceGone: String { String(localized: "importSuggestions.status.sourceGone", defaultValue: "Stopped: the data is no longer there.", table: "ImportSuggestions", bundle: .module) }
    static var failed: String { String(localized: "importSuggestions.status.failed", defaultValue: "The import didn't finish.", table: "ImportSuggestions", bundle: .module) }
    static func done(_ summary: String) -> String {
        String(localized: "importSuggestions.status.done", defaultValue: "Done: \(summary)", table: "ImportSuggestions", bundle: .module)
    }
    static var doneNothing: String { String(localized: "importSuggestions.status.doneNothing", defaultValue: "Done. Nothing new to bring over.", table: "ImportSuggestions", bundle: .module) }
    static var doneChats: String { String(localized: "importSuggestions.status.doneChats", defaultValue: "Your chats are searchable in cmux.", table: "ImportSuggestions", bundle: .module) }
    static var doneTheme: String { String(localized: "importSuggestions.status.doneTheme", defaultValue: "Your colors are a theme now.", table: "ImportSuggestions", bundle: .module) }
    static var doneClassic: String { String(localized: "importSuggestions.status.doneClassic", defaultValue: "Your Classic workspaces are open.", table: "ImportSuggestions", bundle: .module) }

    /// A cmux Classic import's end: the workspaces this run opened.
    static func importedSessions(_ count: Int) -> String {
        String(localized: "importSuggestions.status.importedSessions", defaultValue: "Imported \(count) sessions", table: "ImportSuggestions", bundle: .module)
    }

    static func pages(_ count: Int) -> String {
        String(localized: "importSuggestions.count.pages", defaultValue: "\(count) pages", table: "ImportSuggestions", bundle: .module)
    }
    static func bookmarks(_ count: Int) -> String {
        String(localized: "importSuggestions.count.bookmarks", defaultValue: "\(count) bookmarks", table: "ImportSuggestions", bundle: .module)
    }
    static func cookies(_ count: Int) -> String {
        String(localized: "importSuggestions.count.cookies", defaultValue: "\(count) cookies", table: "ImportSuggestions", bundle: .module)
    }

    // MARK: Refusals and the Home row

    public static func noSuchCard(_ id: String) -> String {
        String(localized: "importSuggestions.refusal.noSuchCard", defaultValue: "No import card \(id).", table: "ImportSuggestions", bundle: .module)
    }
    public static func unknownBrowser(_ name: String) -> String {
        String(localized: "importSuggestions.refusal.unknownBrowser", defaultValue: "cmux can't import from \(name).", table: "ImportSuggestions", bundle: .module)
    }
    public static func invalidSite(_ site: String) -> String {
        String(localized: "importSuggestions.refusal.invalidSite", defaultValue: "\(site) is not a site name, like github.com.", table: "ImportSuggestions", bundle: .module)
    }
    public static func unknownButton(_ action: String) -> String {
        String(localized: "importSuggestions.refusal.unknownButton", defaultValue: "An import card has no \(action) button.", table: "ImportSuggestions", bundle: .module)
    }
    public static var settingsEmpty: String {
        String(localized: "importSuggestions.settings.empty", defaultValue: "Nothing to bring over right now. cmux looks again when you come back to it.",
               table: "ImportSuggestions", bundle: .module)
    }
    /// `import.card` start, resume or try again from an agent, a script or another client.
    public static var personOnly: String {
        String(localized: "importSuggestions.refusal.personOnly", defaultValue: "Only you can start an import: press its button in cmux.",
               table: "ImportSuggestions", bundle: .module)
    }
    /// The native question a page's Import, Resume or Try Again asks first ("Import from Chrome?").
    public static func confirmTitle(_ name: String) -> String {
        String(localized: "importSuggestions.confirm.title", defaultValue: "Import from \(name)?", table: "ImportSuggestions", bundle: .module)
    }
    /// That question's button: the card's own word for the press.
    public static func confirmButton(_ action: ImportCardAction) -> String {
        switch action {
        case .resume: resume
        case .retry: retry
        case .start, .dismiss, .restore, .more, .open, .hide: importButton
        }
    }
    public static var cardsOff: String { String(localized: "importSuggestions.refusal.off", defaultValue: "Import suggestions are turned off in Debug Settings.", table: "ImportSuggestions", bundle: .module) }

    /// "history, cookies and bookmarks" in the person's language.
    static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items.filter { !$0.isEmpty })
    }
}
