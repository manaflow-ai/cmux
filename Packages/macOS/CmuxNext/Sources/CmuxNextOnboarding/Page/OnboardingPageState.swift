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

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(primary, forKey: .primary)
            try c.encode(primaryEnabled, forKey: .primaryEnabled)
            try c.encode(skip, forKey: .skip)
            try c.encode(showsBack, forKey: .showsBack)
            try c.encode(backEnabled, forKey: .backEnabled)
            try c.encodeNullable(progress, forKey: .progress)
        }

        private enum Keys: String, CodingKey { case primary, primaryEnabled, skip, showsBack, backEnabled, progress }
    }

    struct AgentRow: Encodable, Equatable {
        let id: String
        let name: String
        let auth: String
        let offersSignIn: Bool
        let icon: Image?
        /// An agent cmux can install that is not on this Mac; nil (absent) for an installed one.
        let install: Install?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(auth, forKey: .auth)
            try c.encode(offersSignIn, forKey: .offersSignIn)
            try c.encodeNullable(icon, forKey: .icon)
            try c.encodeIfPresent(install, forKey: .install)
        }

        private enum Keys: String, CodingKey { case id, name, auth, offersSignIn, icon, install }
    }

    /// A missing agent's Install: at rest (`idle`), running, or what went wrong, with the vendor's page.
    struct Install: Encodable, Equatable {
        let state: String
        let message: String?
        let vendorURL: String?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(state, forKey: .state)
            try c.encodeNullable(message, forKey: .message)
            try c.encodeNullable(vendorURL, forKey: .vendorURL)
        }

        private enum Keys: String, CodingKey { case state, message, vendorURL }
    }

    struct Agents: Encodable, Equatable {
        let rows: [AgentRow]
        let loaded: Bool
        let signingIn: String?
        let signInFailed: Bool

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(rows, forKey: .rows)
            try c.encode(loaded, forKey: .loaded)
            try c.encodeNullable(signingIn, forKey: .signingIn)
            try c.encode(signInFailed, forKey: .signInFailed)
        }

        private enum Keys: String, CodingKey { case rows, loaded, signingIn, signInFailed }
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

        /// Each kind's own fields; `importing` sends `dataKind` as null before its first kind.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(kind, forKey: .kind)
            if kind == "importing" { try c.encodeNullable(dataKind, forKey: .dataKind) }
            try c.encodeIfPresent(counts, forKey: .counts)
            try c.encodeIfPresent(reason, forKey: .reason)
        }

        private enum Keys: String, CodingKey { case kind, dataKind, counts, reason }
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

        /// A profile row sends each of its nullable fields as null; an awaiting row only its own fields.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(browserName, forKey: .browserName)
            try c.encodeNullable(icon, forKey: .icon)
            guard kind == "profile" else { return try c.encodeIfPresent(browser, forKey: .browser) }
            try c.encodeIfPresent(id, forKey: .id)
            try c.encodeNullable(profileName, forKey: .profileName)
            try c.encodeNullable(avatar, forKey: .avatar)
            try c.encode(needsFullDiskAccess ?? false, forKey: .needsFullDiskAccess)
            try c.encode(checked ?? false, forKey: .checked)
            try c.encodeIfPresent(state, forKey: .state)
            try c.encodeNullable(target, forKey: .target)
        }

        private enum Keys: String, CodingKey {
            case kind, id, browser, browserName, profileName, icon, avatar, needsFullDiskAccess, checked, state, target
        }
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

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(phase, forKey: .phase)
            try c.encodeNullable(failure, forKey: .failure)
            try c.encode(rows, forKey: .rows)
            try c.encode(editable, forKey: .editable)
            try c.encode(targetChoices, forKey: .targetChoices)
            try c.encode(targetFixed, forKey: .targetFixed)
            try c.encode(kindChoices, forKey: .kindChoices)
            try c.encode(kinds, forKey: .kinds)
            try c.encode(keepsHistoryInSync, forKey: .keepsHistoryInSync)
            try c.encode(offersPasswordCSV, forKey: .offersPasswordCSV)
            try c.encodeNullable(summary, forKey: .summary)
            try c.encodeNullable(access, forKey: .access)
            try c.encodeNullable(consent, forKey: .consent)
        }

        private enum Keys: String, CodingKey {
            case phase, failure, rows, editable, targetChoices, targetFixed, kindChoices, kinds, keepsHistoryInSync,
                 offersPasswordCSV, summary, access, consent
        }
    }

    struct GrantRow: Encodable, Equatable {
        let pane: String
        let control: String
        let icon: Image?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(pane, forKey: .pane)
            try c.encode(control, forKey: .control)
            try c.encodeNullable(icon, forKey: .icon)
        }

        private enum Keys: String, CodingKey { case pane, control, icon }
    }

    struct ComputerUse: Encodable, Equatable {
        let helperIcon: Image?
        let rows: [GrantRow]
        let allGranted: Bool
        let note: String?
        let showsRestart: Bool
        let comebacks: Int

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeNullable(helperIcon, forKey: .helperIcon)
            try c.encode(rows, forKey: .rows)
            try c.encode(allGranted, forKey: .allGranted)
            try c.encodeNullable(note, forKey: .note)
            try c.encode(showsRestart, forKey: .showsRestart)
            try c.encode(comebacks, forKey: .comebacks)
        }

        private enum Keys: String, CodingKey { case helperIcon, rows, allGranted, note, showsRestart, comebacks }
    }

    let step: String
    let footer: Footer
    let agents: Agents?
    let importer: Importer?
    let computerUse: ComputerUse?

    /// Every field `ops.ts` types `T | null` is sent, as null when absent: the page reads `null`, never a
    /// missing key. (Synthesized `Encodable` leaves a nil out, so each such struct encodes itself.)
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(step, forKey: .step)
        try container.encode(footer, forKey: .footer)
        try container.encodeNullable(agents, forKey: .agents)
        try container.encodeNullable(importer, forKey: .importer)
        try container.encodeNullable(computerUse, forKey: .computerUse)
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
        let installed = model.agents.map { agent in
            AgentRow(id: agent.id, name: agent.name, auth: agent.auth.rawValue, offersSignIn: agent.offersSignIn,
                     icon: images.agent(agent, source: model.source), install: nil)
        }
        let installable = model.installable.map { agent in
            AgentRow(id: agent.id, name: agent.name, auth: agent.auth.rawValue, offersSignIn: false,
                     icon: images.agent(agent, source: model.source), install: install(model.installs[agent.id], page: agent.installPage))
        }
        return Agents(rows: installed + installable, loaded: model.loaded, signingIn: model.signingIn, signInFailed: model.signInFailed)
    }

    nonisolated static func install(_ install: AgentsStepModel.Install?, page: URL?) -> Install {
        switch install {
        case nil: Install(state: "idle", message: nil, vendorURL: page?.absoluteString)
        case .installing: Install(state: "installing", message: nil, vendorURL: page?.absoluteString)
        case .failed(let message): Install(state: "failed", message: message, vendorURL: page?.absoluteString)
        }
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

private nonisolated extension KeyedEncodingContainer {
    /// `value`, or JSON null when it is nil (never a missing key).
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
