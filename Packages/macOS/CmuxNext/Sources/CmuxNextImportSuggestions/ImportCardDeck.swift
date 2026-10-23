public import CmuxNextBrowserImport
public import Foundation

/// The cards Settings › Import lists, from what the scan found, what the person
/// dismissed, the Chief's requests and the jobs: everything found, dismissed ones
/// too. Pure, so every rule here is a unit test. Home and New Tab show no cards.
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
        var cards: [ImportCard] = []
        var placed = Set<String>()
        // The Chief's requests lead: they answer something the person just ran into.
        for request in state.requests where jobs.job(request.id) == nil {
            cards.append(card(for: request))
            placed.insert(request.id)
        }
        // Jobs: running and paused first, then failed, then finished.
        let order: [ImportJob.Phase: Int] = [.running: 0, .paused: 1, .failed: 2, .done: 3]
        for job in jobs.jobs.sorted(by: { (order[$0.phase] ?? 9, $1.updatedAt) < (order[$1.phase] ?? 9, $0.updatedAt) }) {
            guard !placed.contains(job.id) else { continue }
            placed.insert(job.id)
            cards.append(card(for: job, finding: findings.first { $0.id == job.id }))
        }
        for finding in findings where !placed.contains(finding.id) {
            cards.append(card(for: finding, dismissed: state.hides(finding)))
        }
        return cards
    }

    // MARK: Cards

    func app(_ finding: ImportFinding) -> String? {
        if let browser = finding.browser { return apps[finding.id] ?? browser.bundleIDs.first }
        return apps[finding.id]
    }

    func facts(_ finding: ImportFinding) -> String {
        switch finding.kind {
        case .browser:
            if finding.access == .needsFullDiskAccess { return ImportSuggestionStrings.needsFullDiskAccess }
            let kinds = ImportSuggestionStrings.list(finding.kinds.map(ImportSuggestionStrings.kind))
            // Safari has one store, no profiles to count.
            guard finding.browser?.family != .safari else { return kinds }
            return "\(ImportSuggestionStrings.profiles(finding.profiles.count)) · \(kinds)"
        case .claudeCode: return ImportSuggestionStrings.sessions(finding.count)
        case .codex: return ImportSuggestionStrings.threads(finding.count)
        case .cmuxClassic:
            return finding.offersNothingNew ? ImportSuggestionStrings.classicAllHere : ImportSuggestionStrings.workspaces(finding.count)
        case .iterm2: return ImportSuggestionStrings.profiles(finding.count)
        case .ghostty: return ImportSuggestionStrings.inUse
        }
    }

    func benefit(_ finding: ImportFinding) -> String {
        switch finding.kind {
        case .browser:
            if finding.access == .needsFullDiskAccess { return ImportSuggestionStrings.safariAccess }
            return finding.kinds.contains(.cookies) ? ImportSuggestionStrings.browserSignedIn(finding.name)
                : ImportSuggestionStrings.browserHistory(finding.name)
        case .claudeCode: return ImportSuggestionStrings.claudeCode
        case .codex: return ImportSuggestionStrings.codex
        case .cmuxClassic: return finding.offersNothingNew ? ImportSuggestionStrings.classicAgain : ImportSuggestionStrings.classic
        case .iterm2: return ImportSuggestionStrings.iterm2
        case .ghostty: return ImportSuggestionStrings.ghostty
        }
    }

    /// The button that imports this source.
    static func startButton(_ kind: ImportSourceKind) -> ImportCard.Button {
        switch kind {
        case .browser: .init(.start, ImportSuggestionStrings.importButton)
        case .claudeCode, .codex: .init(.start, ImportSuggestionStrings.showChats)
        case .cmuxClassic: .init(.start, ImportSuggestionStrings.importWorkspaces)
        case .iterm2: .init(.start, ImportSuggestionStrings.importColors)
        case .ghostty: .init(.open, ImportSuggestionStrings.openConfig)
        }
    }

    func card(for finding: ImportFinding, dismissed: Bool) -> ImportCard {
        var primary: ImportCard.Button? = finding.offersNothingNew ? .init(.start, ImportSuggestionStrings.importAgain) : Self.startButton(finding.kind)
        var secondary: [ImportCard.Button] = []
        var state = ImportCard.State.ready
        if finding.access == .needsFullDiskAccess {
            primary = .init(.open, ImportSuggestionStrings.openSystemSettings)
            state = .info
        } else if finding.access == .inUse {
            state = .info
        }
        if finding.kind == .browser, finding.access == .ready { secondary.append(.init(.more, ImportSuggestionStrings.more)) }
        if dismissed {
            secondary.append(.init(.restore, ImportSuggestionStrings.showAgain))
        } else if finding.access != .inUse {
            secondary.append(.init(.dismiss, ImportSuggestionStrings.notNow))
        }
        return ImportCard(id: finding.id, kind: finding.kind, app: app(finding), title: finding.name, facts: facts(finding),
                          benefit: benefit(finding), state: state, primary: primary, secondary: secondary, dismissed: dismissed)
    }

    func card(for request: ImportRequest) -> ImportCard {
        ImportCard(id: request.id, kind: .browser, app: apps["browser.\(request.browser.rawValue)"] ?? request.browser.bundleIDs.first,
                   title: ImportSuggestionStrings.requestTitle(browser: request.browser.displayName, site: request.site),
                   facts: ImportSuggestionStrings.requestedBy(ImportSuggestionStrings.chief),
                   benefit: ImportSuggestionStrings.request(site: request.site), reason: request.reason.isEmpty ? nil : request.reason,
                   requestedBy: ImportSuggestionStrings.chief, state: .ready,
                   primary: .init(.start, ImportSuggestionStrings.importButton), secondary: [.init(.dismiss, ImportSuggestionStrings.notNow)])
    }

    func card(for job: ImportJob, finding: ImportFinding?) -> ImportCard {
        let name = finding?.name ?? job.browser?.displayName ?? job.kind.displayName
        let title = job.site.map { ImportSuggestionStrings.requestTitle(browser: name, site: $0) } ?? name
        let factsText = finding.map { self.facts($0) } ?? ""
        let benefitText = job.site.map { ImportSuggestionStrings.request(site: $0) } ?? finding.map { self.benefit($0) } ?? ""
        var card = ImportCard(id: job.id, kind: job.kind, app: job.browser?.bundleIDs.first ?? finding.flatMap { self.app($0) }, title: title,
                              facts: factsText, benefit: benefitText, state: .running, progress: job.fraction, primary: nil, secondary: [])
        switch job.phase {
        case .running:
            card.status = ImportSuggestionStrings.running
        case .paused:
            card.state = .paused
            card.status = job.pause == .needsPerson ? ImportSuggestionStrings.needsPerson : ImportSuggestionStrings.interrupted
            card.primary = .init(.resume, ImportSuggestionStrings.resume)
            card.secondary = [.init(.hide, ImportSuggestionStrings.notNow)]
        case .failed:
            card.state = .failed
            card.progress = nil
            card.status = switch job.failure {
            case .declined: ImportSuggestionStrings.declined
            case .sourceGone: ImportSuggestionStrings.sourceGone
            case .importFailed, nil: ImportSuggestionStrings.failed
            }
            card.primary = .init(.retry, ImportSuggestionStrings.retry)
            card.secondary = [.init(.hide, ImportSuggestionStrings.notNow)]
        case .done:
            card.state = .done
            card.progress = nil
            card.status = Self.doneStatus(job)
            switch job.kind {
            case .claudeCode, .codex: card.primary = .init(.open, ImportSuggestionStrings.showChats)
            case .iterm2: card.primary = .init(.open, ImportSuggestionStrings.openAppearance)
            // Settings › Import runs it again while Classic has a saved session; the ledger brings nothing twice.
            case .cmuxClassic: card.primary = finding != nil ? .init(.start, ImportSuggestionStrings.importAgain) : nil
            case .browser, .ghostty: card.primary = nil
            }
            card.secondary = [.init(.hide, ImportSuggestionStrings.done)]
        }
        return card
    }

    static func doneStatus(_ job: ImportJob) -> String {
        switch job.kind {
        case .claudeCode, .codex: return ImportSuggestionStrings.doneChats
        case .iterm2: return ImportSuggestionStrings.doneTheme
        case .cmuxClassic: return job.opened.map(ImportSuggestionStrings.importedSessions) ?? ImportSuggestionStrings.doneClassic
        case .ghostty: return ImportSuggestionStrings.doneNothing
        case .browser:
            var parts: [String] = []
            if job.counts.history > 0 { parts.append(ImportSuggestionStrings.pages(job.counts.history)) }
            if job.counts.bookmarks > 0 { parts.append(ImportSuggestionStrings.bookmarks(job.counts.bookmarks)) }
            if job.counts.cookies > 0 { parts.append(ImportSuggestionStrings.cookies(job.counts.cookies)) }
            return parts.isEmpty ? ImportSuggestionStrings.doneNothing : ImportSuggestionStrings.done(ImportSuggestionStrings.list(parts))
        }
    }
}

extension ImportSourceKind {
    /// The source's name when no scan names it (a job whose source went away).
    nonisolated var displayName: String {
        switch self {
        case .browser: ""
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .ghostty: "Ghostty"
        case .iterm2: "iTerm2"
        case .cmuxClassic: "cmux Classic"
        }
    }
}
