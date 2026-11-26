public import CmuxNextBrowserImport
public import Foundation

/// The cards Settings › Import lists, from what the scan found, what the person
/// dismissed, the Chief's requests and the jobs: everything found, dismissed ones
/// too. Rust decides them (`import_suggest_cards`, cmux-import-suggest's `Deck`, with the
/// tests); this puts the person's words on its keys. Home and New Tab show no cards.
public nonisolated struct ImportCardDeck: Sendable {
    public var findings: [ImportFinding]
    public var state: ImportSuggestionState
    public var jobs: ImportJobLedger
    /// The source apps' bundle ids, for icons (the browser registry's first id).
    public var apps: [String: String]

    public init(findings: [ImportFinding], state: ImportSuggestionState, jobs: ImportJobLedger, apps: [String: String] = [:]) {
        self.findings = findings
        self.state = state
        self.jobs = jobs
        self.apps = apps
    }

    public func list() -> ImportCardList {
        ImportCardList(title: ImportSuggestionStrings.settingsTitle, cards: cards())
    }

    public func cards() -> [ImportCard] {
        let known = findings.compactMap(\.browser) + jobs.jobs.compactMap(\.browser) + state.requests.map(\.browser)
        var browsers: [String: BrowserFacts] = [:]
        for browser in known {
            browsers[browser.rawValue] = BrowserFacts(family: browser.family.rawValue, app: browser.bundleIDs.first, name: browser.displayName)
        }
        let fields: [String: any Encodable] = ["findings": findings, "state": state, "jobs": jobs, "apps": apps, "browsers": browsers]
        return (ImportSuggestRules.call("cards", fields, as: [Card].self) ?? []).map(\.card)
    }

    /// What the registry says about a browser, which Rust cannot look up.
    private struct BrowserFacts: Encodable {
        var family: String
        var app: String?
        var name: String
    }

    /// One card as Rust lays it out: keys where the words go.
    private struct Card: Decodable {
        var id: String
        var kind: ImportSourceKind
        var app: String?
        var title: ImportText
        var facts: ImportText
        var benefit: ImportText
        var reason: String?
        var requestedByChief: Bool
        var state: ImportCard.State
        var progress: Double?
        var status: ImportText?
        var primary: Button?
        var secondary: [Button]
        var dismissed: Bool

        struct Button: Decodable {
            var action: ImportCardAction
            var label: ImportLabel

            var button: ImportCard.Button { ImportCard.Button(action, ImportSuggestionStrings.label(label)) }
        }

        var card: ImportCard {
            ImportCard(id: id, kind: kind, app: app, title: title.words, facts: facts.words, benefit: benefit.words, reason: reason,
                       requestedBy: requestedByChief ? ImportSuggestionStrings.chief : nil, state: state, progress: progress,
                       status: status?.words, primary: primary?.button, secondary: secondary.map(\.button), dismissed: dismissed)
        }
    }
}

/// A button's word, as Rust names it (`deck::Label`).
nonisolated enum ImportLabel: String, Decodable, Sendable {
    case importButton = "import"
    case showChats, importWorkspaces, importAgain, importColors, openConfig, openSystemSettings, openAppearance
    case more, notNow, showAgain, resume, retry, done
}

/// A card's text, as Rust names it (`deck::Text`): the key and what goes in the words.
nonisolated struct ImportText: Decodable, Sendable {
    var key: String
    var value: String?
    var kinds: [ImportDataKind]?
    var profiles: Int?
    var count: Int?
    var name: String?
    var site: String?
    var browser: String?
    var pages: Int?
    var bookmarks: Int?
    var cookies: Int?

    /// The text in the person's language.
    var words: String {
        typealias S = ImportSuggestionStrings
        let count = count ?? 0
        switch key {
        case "literal": return value ?? ""
        case "needsFullDiskAccess": return S.needsFullDiskAccess
        case "kinds": return S.list((kinds ?? []).map(S.kind))
        case "profilesAndKinds": return "\(S.profiles(profiles ?? 0)) · \(S.list((kinds ?? []).map(S.kind)))"
        case "sessions": return S.sessions(count)
        case "threads": return S.threads(count)
        case "workspaces": return S.workspaces(count)
        case "profiles": return S.profiles(count)
        case "classicAllHere": return S.classicAllHere
        case "inUse": return S.inUse
        case "requestedByChief": return S.requestedBy(S.chief)
        case "safariAccess": return S.safariAccess
        case "browserSignedIn": return S.browserSignedIn(name ?? "")
        case "browserHistory": return S.browserHistory(name ?? "")
        case "claudeCode": return S.claudeCode
        case "codex": return S.codex
        case "classic": return S.classic
        case "classicAgain": return S.classicAgain
        case "conductor": return S.conductor
        case "iterm2": return S.iterm2
        case "ghostty": return S.ghostty
        case "request": return S.request(site: site ?? "")
        case "requestTitle": return S.requestTitle(browser: browser ?? "", site: site ?? "")
        case "running": return S.running
        case "needsPerson": return S.needsPerson
        case "interrupted": return S.interrupted
        case "declined": return S.declined
        case "sourceGone": return S.sourceGone
        case "failed": return S.failed
        case "doneChats": return S.doneChats
        case "doneTheme": return S.doneTheme
        case "doneClassic": return S.doneClassic
        case "doneConductor": return S.doneConductor
        case "doneNothing": return S.doneNothing
        case "done": return S.done
        case "importedSessions": return S.importedSessions(count)
        case "doneCounts":
            let parts = [(pages ?? 0, S.pages), (bookmarks ?? 0, S.bookmarks), (cookies ?? 0, S.cookies)]
                .compactMap { number, words in number > 0 ? words(number) : nil }
            return parts.isEmpty ? S.doneNothing : S.done(S.list(parts))
        default: return ""
        }
    }
}

extension ImportSuggestionStrings {
    /// A button's word.
    static func label(_ label: ImportLabel) -> String {
        switch label {
        case .importButton: importButton
        case .showChats: showChats
        case .importWorkspaces: importWorkspaces
        case .importAgain: importAgain
        case .importColors: importColors
        case .openConfig: openConfig
        case .openSystemSettings: openSystemSettings
        case .openAppearance: openAppearance
        case .more: more
        case .notNow: notNow
        case .showAgain: showAgain
        case .resume: resume
        case .retry: retry
        case .done: done
        }
    }
}
