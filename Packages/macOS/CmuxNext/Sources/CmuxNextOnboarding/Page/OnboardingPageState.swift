import CmuxNextBrowserImport
import Foundation

/// The onboarding page's state (`webviews/src/pages/onboarding/ops.ts`, `OnboardingState`): what
/// the window's model shows, as values. The page owns every sentence; this sends no text but
/// names, paths, counts and the host's own failure lines.
nonisolated struct OnboardingPageState: Encodable, Equatable {
    struct Image: Encodable, Equatable {
        let src: String
        let template: Bool
    }

    struct Footer: Encodable, Equatable {
        let primary: String
        let primaryEnabled: Bool
        let skip: String
        let showsBack: Bool
        let backEnabled: Bool
        let progress: Double?
    }

    struct AgentRow: Encodable, Equatable {
        let id: String
        let name: String
        let auth: String
        let offersSignIn: Bool
        let icon: Image?
    }

    struct Agents: Encodable, Equatable {
        let rows: [AgentRow]
        let loaded: Bool
        let signingIn: String?
        let signInFailed: Bool
    }

    struct Counts: Encodable, Equatable {
        let bookmarks: Int
        let history: Int
        let openTabs: Int
        let cookies: Int
        let passwords: Int
        let searchEngines: Int

        init(_ counts: ImportCounts) {
            bookmarks = counts.bookmarks
            history = counts.history
            openTabs = counts.openTabs
            cookies = counts.cookies
            passwords = counts.passwords
            searchEngines = counts.searchEngines
        }
    }

    struct RowState: Encodable, Equatable {
        let kind: String
        var dataKind: String?
        var counts: Counts?
        var reason: String?
    }

    struct ImportRow: Encodable, Equatable {
        let kind: String
        var id: String?
        var browser: String?
        let browserName: String
        var profileName: String?
        let icon: Image?
        var avatar: Image?
        var needsFullDiskAccess: Bool?
        var checked: Bool?
        var state: RowState?
        var target: String?
    }

    struct Target: Encodable, Equatable {
        let id: String
        let name: String
    }

    struct Summary: Encodable, Equatable {
        let counts: Counts
        let passwordsSkipped: Int
        let passwordsConflicts: Int
        let passwordsNotRead: Bool
        let someFailed: Bool
    }

    struct Access: Encodable, Equatable {
        let browserName: String
        let folder: String
        let requesting: Bool
        let notGranted: Bool
    }

    struct Consent: Encodable, Equatable {
        let keychainItems: [String]
        let includesFirefox: Bool
        let authorizing: Bool
        let denied: Bool
    }

    struct Importer: Encodable, Equatable {
        let phase: String
        let failure: String?
        let rows: [ImportRow]
        let editable: Bool
        let targetChoices: [Target]
        let targetFixed: Bool
        let kindChoices: [String]
        let kinds: [String]
        let keepsHistoryInSync: Bool
        let offersPasswordCSV: Bool
        let summary: Summary?
        let access: Access?
        let consent: Consent?
    }

    struct GrantRow: Encodable, Equatable {
        let pane: String
        let control: String
        let icon: Image?
    }

    struct ComputerUse: Encodable, Equatable {
        let helperIcon: Image?
        let rows: [GrantRow]
        let allGranted: Bool
        let note: String?
        let showsRestart: Bool
        let comebacks: Int
    }

    let step: String
    let footer: Footer
    let agents: Agents?
    let importer: Importer?
    let computerUse: ComputerUse?

    /// Every optional is sent, as null when absent: the page reads `null`, never a missing key.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(step, forKey: .step)
        try container.encode(footer, forKey: .footer)
        try container.encode(agents, forKey: .agents)
        try container.encode(importer, forKey: .importer)
        try container.encode(computerUse, forKey: .computerUse)
    }

    private enum Keys: String, CodingKey { case step, footer, agents, importer, computerUse }
}

extension OnboardingPageState {
    /// The state of `model`'s window; `images` draws the icons (nil until drawn).
    @MainActor
    init(model: OnboardingModel, images: OnboardingPageImages) {
        step = model.step.rawValue
        footer = Footer(primary: Self.primary(model), primaryEnabled: model.canAdvance,
                        skip: model.step == .importData && model.importer.isConfirmingPasswords ? "skipImporting" : "skip",
                        showsBack: model.flowProgress != nil, backEnabled: model.canGoBack, progress: model.flowProgress)
        agents = model.step == .agents ? Self.agents(model.agents, images) : nil
        importer = model.step == .importData ? Self.importer(model.importer, images) : nil
        computerUse = model.step == .computerUse ? Self.computerUse(model.computerUse, images) : nil
    }

    /// `OnboardingModel.primaryTitle`, as the page's label key.
    @MainActor
    static func primary(_ model: OnboardingModel) -> String {
        let importer = model.importer
        switch model.step {
        case .agents: return "continue"
        case .computerUse: return "done"
        case .importData:
            if importer.phase == .detecting { return "detecting" }
            if importer.phase == .idle { return "findBrowsers" }
            if importer.explainingAccess != nil { return "continue" }
            if importer.isConfirmingPasswords { return "beginImporting" }
            return importer.canStart ? "import" : "done"
        }
    }

    @MainActor
    private static func agents(_ model: AgentsStepModel, _ images: OnboardingPageImages) -> Agents {
        Agents(rows: model.agents.map { agent in
            AgentRow(id: agent.id, name: agent.name, auth: agent.auth.rawValue, offersSignIn: agent.offersSignIn,
                     icon: images.agent(agent, source: model.source))
        }, loaded: model.loaded, signingIn: model.signingIn, signInFailed: model.signInFailed)
    }

    @MainActor
    private static func importer(_ model: ImportStepModel, _ images: OnboardingPageImages) -> Importer {
        let apps = Dictionary(model.sources.map { ($0.browser, $0.appURL) }, uniquingKeysWith: { first, _ in first })
        let blocked = Set(model.sources.filter(\.needsFullDiskAccess).map(\.browser))
        var rows: [ImportRow] = model.profiles.map { profile in
            let showsProfile = !(profile.directoryName.isEmpty || profile.browser.family == .safari || profile.browser.family.isPrivateStore)
            return ImportRow(kind: "profile", id: profile.id, browserName: profile.browser.displayName,
                             profileName: showsProfile ? profile.displayName : nil,
                             icon: images.browser(profile.browser, appURL: apps[profile.browser] ?? nil),
                             avatar: profile.avatar.flatMap(images.avatar),
                             needsFullDiskAccess: blocked.contains(profile.browser) || profile.needsFullDiskAccess,
                             checked: model.isSelected(profile), state: rowState(model.rowState(profile)),
                             target: model.target(profile))
        }
        rows += model.awaitingAccess.map { browser in
            ImportRow(kind: "awaiting", browser: browser.rawValue, browserName: browser.displayName,
                      icon: images.browser(browser, appURL: nil))
        }
        return Importer(phase: phase(model.phase), failure: failure(model.phase), rows: rows, editable: model.canEditSelection,
                        targetChoices: model.targetChoices.map { Target(id: $0.id, name: $0.name) },
                        targetFixed: model.mergeTarget != nil,
                        kindChoices: model.kindChoices.map(\.rawValue),
                        kinds: model.kindChoices.filter(model.kinds.contains).map(\.rawValue),
                        keepsHistoryInSync: model.keepsHistoryInSync, offersPasswordCSV: model.offersPasswordCSV,
                        summary: model.summary.map(summary), access: access(model), consent: consent(model))
    }

    private static func phase(_ phase: ImportStepModel.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .detecting: "detecting"
        case .ready: "ready"
        case .explainingAccess: "explainingAccess"
        case .confirmingPasswords: "confirmingPasswords"
        case .importing: "importing"
        case .finished: "finished"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    private static func failure(_ phase: ImportStepModel.Phase) -> String? {
        if case .failed(let message) = phase { message } else { nil }
    }

    private static func rowState(_ state: ImportStepModel.RowState) -> RowState {
        switch state {
        case .idle: RowState(kind: "idle")
        case .waiting: RowState(kind: "waiting")
        case .importing(let kind, let counts): RowState(kind: "importing", dataKind: kind?.rawValue, counts: Counts(counts))
        case .done(let counts): RowState(kind: "done", counts: Counts(counts))
        case .failed(let reason): RowState(kind: "failed", reason: reason)
        }
    }

    private static func summary(_ summary: ImportSummary) -> Summary {
        let passwords = summary.batches.compactMap(\.passwords)
        return Summary(counts: Counts(summary.counts),
                       passwordsSkipped: passwords.reduce(0) { $0 + $1.notImportedOtherThanConflicts },
                       passwordsConflicts: passwords.reduce(0) { $0 + $1.conflicts },
                       passwordsNotRead: summary.batches.contains { $0.passwordError != nil },
                       someFailed: !summary.failures.isEmpty)
    }

    @MainActor
    private static func access(_ model: ImportStepModel) -> Access? {
        guard let browser = model.explainingAccess else { return nil }
        return Access(browserName: browser.displayName, folder: displayPath(model.folderPath(browser)),
                      requesting: model.requestingAccess, notGranted: model.accessNotGranted)
    }

    @MainActor
    private static func consent(_ model: ImportStepModel) -> Consent? {
        guard model.isConfirmingPasswords else { return nil }
        return Consent(keychainItems: model.passwordKeychainItems, includesFirefox: model.passwordsIncludeFirefox,
                       authorizing: model.authorizing, denied: model.authorizationDenied)
    }

    /// `~/Library/Application Support/Google/Chrome` for a folder in the home directory.
    static func displayPath(_ url: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard let url else { return "" }
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return (path as NSString).abbreviatingWithTildeInPath }
        return "~" + path.dropFirst(homePath.count)
    }

    @MainActor
    private static func computerUse(_ model: ComputerUseStepModel, _ images: OnboardingPageImages) -> ComputerUse {
        ComputerUse(helperIcon: images.helper(model.helperAppURL),
                    rows: ComputerUsePermissionPane.allCases.map { pane in
                        GrantRow(pane: pane.rawValue, control: control(pane, model), icon: images.grant(pane))
                    },
                    allGranted: model.allGranted, note: note(model), showsRestart: model.permissions.helperFailed,
                    comebacks: model.comebacks)
    }

    /// The row's trailing control for the current grants.
    @MainActor
    static func control(_ pane: ComputerUsePermissionPane, _ model: ComputerUseStepModel) -> String {
        let permissions = model.permissions
        if permissions.helperFailed || permissions.helperVersionMismatch { return "hidden" }
        if permissions.granted(pane) { return "done" }
        return model.isPrimary(pane) ? "allowPrimary" : "allow"
    }

    /// The footer's one line on why Allow cannot help, if it cannot.
    @MainActor
    static func note(_ model: ComputerUseStepModel) -> String? {
        let permissions = model.permissions
        if permissions.helperFailed { return "helperFailed" }
        if permissions.helperVersionMismatch { return "helperVersionMismatch" }
        if model.unavailable { return "unavailable" }
        if permissions.isOff { return "off" }
        return nil
    }
}
