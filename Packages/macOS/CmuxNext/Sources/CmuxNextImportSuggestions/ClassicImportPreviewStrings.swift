public import Foundation

/// The classic import prompt's words (table `ImportSuggestions`), in plain sentences (Leo 2026-11-15, on the
/// label-and-number list it replaced: "this is kinda strange. what happened here?") for one classic save: what comes
/// over and when classic saved it, what opening it does, then only the cautions that apply. A count of zero never shows.
public nonisolated struct ClassicImportPreviewStrings: Equatable, Sendable {
    /// What one classic save brings, as the daemon previewed it.
    public var workspaces, browserTabs, filePages, sshWorkspaces, agentChats, skippedCloudVMs, cleanup: Int

    public init(workspaces: Int, browserTabs: Int = 0, filePages: Int = 0, sshWorkspaces: Int = 0, agentChats: Int = 0,
                skippedCloudVMs: Int = 0, cleanup: Int = 0) {
        self.workspaces = workspaces
        self.browserTabs = browserTabs
        self.filePages = filePages
        self.sshWorkspaces = sshWorkspaces
        self.agentChats = agentChats
        self.skippedCloudVMs = skippedCloudVMs
        self.cleanup = cleanup
    }

    public static var consentTitle: String {
        String(localized: "classicImport.preview.consentTitle", defaultValue: "Import from classic cmux?",
               table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var consentData: String {
        String(localized: "classicImport.preview.consentData", defaultValue: "Import your settings, shortcuts, palette history, terminal configuration and saved workspaces.",
               table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var consentEffects: String {
        String(localized: "classicImport.preview.consentEffects", defaultValue: "Opening saved workspaces can reconnect SSH hosts, load pages and resume agent chats.",
               table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var title: String {
        String(localized: "classicImport.preview.title", defaultValue: "Import your classic cmux workspaces?", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var importButton: String {
        String(localized: "classicImport.preview.button", defaultValue: "Import", table: "ImportSuggestions", bundle: .localizedModule)
    }
    /// The launch's Cancel: its prompt says where the import waits (``later``).
    public static var notNow: String {
        String(localized: "classicImport.preview.notNow", defaultValue: "Not Now", table: "ImportSuggestions", bundle: .localizedModule)
    }

    /// The prompt's lines for this save of classic app `app` (as its Dock names it). At launch the last line says
    /// where the import waits. Which lines, parts and effects show is Rust's (`preview::Counts::lines`).
    public func lines(app: String, savedAt: Date, classicRunning: Bool, atLaunch: Bool) -> [String] {
        plan(classicRunning: classicRunning, atLaunch: atLaunch).map { $0.words(app: app, savedAt: savedAt) }
    }

    /// "8 workspaces, 2 browser tabs and 1 agent chat from cmux, saved today at 1:47 PM." Workspaces always (a
    /// run may only replace interrupted ones); the rest only when there are some.
    public func summary(app: String, savedAt: Date, classicRunning: Bool) -> String {
        plan(classicRunning: classicRunning, atLaunch: false).first { $0.line == "summary" }?.words(app: app, savedAt: savedAt) ?? ""
    }

    private func plan(classicRunning: Bool, atLaunch: Bool) -> [Line] {
        let counts = ["workspaces": workspaces, "browserTabs": browserTabs, "filePages": filePages, "sshWorkspaces": sshWorkspaces,
                      "agentChats": agentChats, "skippedCloudVMs": skippedCloudVMs, "cleanup": cleanup]
        return ImportSuggestRules.call("classic_lines", ["counts": counts, "classicRunning": classicRunning, "atLaunch": atLaunch],
                                       as: [Line].self) ?? []
    }

    /// One line as Rust plans it (`preview::Line`).
    private struct Line: Decodable {
        struct Counted: Decodable {
            var part: String
            var count: Int
        }

        var line: String
        var parts: [Counted]?
        var autosaved: Bool?
        var effects: [String]?
        var count: Int?

        func words(app: String, savedAt: Date) -> String {
            typealias S = ClassicImportPreviewStrings
            switch line {
            case "summary":
                let parts = (parts ?? []).map { counted in
                    switch counted.part {
                    case "browserTabs": S.browserTabs(counted.count)
                    case "filePages": S.filePages(counted.count)
                    case "sshWorkspaces": S.sshWorkspaces(counted.count)
                    case "agentChats": S.agentChats(counted.count)
                    default: S.workspaces(counted.count)
                    }
                }
                let format = autosaved == true
                    ? String(localized: "classicImport.preview.summaryAutosaved", defaultValue: "%1$@ from %2$@, autosaved %3$@.", table: "ImportSuggestions", bundle: .localizedModule)
                    : String(localized: "classicImport.preview.summarySaved", defaultValue: "%1$@ from %2$@, saved %3$@.", table: "ImportSuggestions", bundle: .localizedModule)
                return String(format: format, ListFormatter.localizedString(byJoining: parts), app, S.savedWhen(savedAt))
            case "opensAsSaved":
                let effects = (effects ?? []).map { effect in
                    switch effect {
                    case "hostsConnect": S.hostsConnect
                    case "chatsResume": S.chatsResume
                    default: S.pagesLoad
                    }
                }
                return effects.isEmpty ? S.opensAsSaved : String(format: S.opensAsSavedDoing, ListFormatter.localizedString(byJoining: effects))
            case "stillOpen": return String(format: S.stillOpen, app)
            case "cloudVmsSkipped": return S.cloudVMsSkipped(count ?? 0)
            case "interruptedClose": return S.interruptedClose(count ?? 0)
            case "later": return S.later
            default: return ""
            }
        }
    }

    /// "today at 1:47 PM", "yesterday at 9:05 AM", else "Nov 3, 2026 at 1:47 PM", inside a sentence.
    public static func savedWhen(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.formattingContext = .middleOfSentence
        return formatter.string(from: date)
    }

    public static func workspaces(_ count: Int) -> String {
        String(localized: "classicImport.preview.workspaces", defaultValue: "\(count) workspaces", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static func browserTabs(_ count: Int) -> String {
        String(localized: "classicImport.preview.browserTabs", defaultValue: "\(count) browser tabs", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static func filePages(_ count: Int) -> String {
        String(localized: "classicImport.preview.filePages", defaultValue: "\(count) file pages", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static func sshWorkspaces(_ count: Int) -> String {
        String(localized: "classicImport.preview.sshWorkspaces", defaultValue: "\(count) SSH workspaces", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static func agentChats(_ count: Int) -> String {
        String(localized: "classicImport.preview.agentChats", defaultValue: "\(count) agent chats", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static func cloudVMsSkipped(_ count: Int) -> String {
        String(localized: "classicImport.preview.cloudVMsSkipped", defaultValue: "\(count) Cloud VM workspaces stay in classic cmux.",
               table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static func interruptedClose(_ count: Int) -> String {
        String(localized: "classicImport.preview.interruptedClose",
               defaultValue: "\(count) workspaces left by an interrupted import close first, and their terminals end.",
               table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var opensAsSaved: String {
        String(localized: "classicImport.preview.opensAsSaved", defaultValue: "They open exactly as classic saved them.", table: "ImportSuggestions", bundle: .localizedModule)
    }
    /// "They open exactly as classic saved them: pages load, SSH hosts connect and agent chats resume."
    public static var opensAsSavedDoing: String {
        String(localized: "classicImport.preview.opensAsSavedDoing", defaultValue: "They open exactly as classic saved them: %@.",
               table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var pagesLoad: String {
        String(localized: "classicImport.preview.pagesLoad", defaultValue: "pages load", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var hostsConnect: String {
        String(localized: "classicImport.preview.hostsConnect", defaultValue: "SSH hosts connect", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var chatsResume: String {
        String(localized: "classicImport.preview.chatsResume", defaultValue: "agent chats resume", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var stillOpen: String {
        String(localized: "classicImport.preview.stillOpen",
               defaultValue: "%@ is still open, so this is its last autosave. Quit it first to bring its latest state.",
               table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var later: String {
        String(localized: "classicImport.preview.later", defaultValue: "You can import them later from Settings › Import.",
               table: "ImportSuggestions", bundle: .localizedModule)
    }

    /// The toast after the launch's Not Now: one short line, and ``importAgain`` asks again (Leo 2026-11-15, on
    /// the two-sentence toast with Don't Show Again it replaced: "the styling for that + this is just kinda awkward").
    public static var notImported: String {
        String(localized: "classicImport.toast.notImported", defaultValue: "Classic workspaces weren’t imported.", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var importAgain: String {
        String(localized: "classicImport.toast.importAgain", defaultValue: "Import…", table: "ImportSuggestions", bundle: .localizedModule)
    }

    /// The classic app that saves under `bundle` (a classic bundle id), as its Dock names it (Rust's `preview::app_name`).
    public static func appName(_ bundle: String) -> String {
        ImportSuggestRules.call("app_name", ["bundle": bundle, "classic": "com.cmuxterm.app"], as: String.self) ?? "cmux DEV"
    }
}
