/// The words and buttons of the cookie import permission card for one phase, in the person's
/// language: one model every host draws (the inline card in Home, the window card, an agent chat's
/// tool card as ``plainText``), so all of them say the same thing.
///
/// The asking card answers, in this order: who asks, why (the agent's own words, labeled as
/// such), what exactly will be read (which browser profile, which sites, a warning when it is every
/// site), where it goes (which cmux profile), what macOS will ask next and what to choose there,
/// and that nothing leaves this Mac and it can be removed later.
struct CookieImportCardText: Equatable {
    /// One labeled fact ("From", "Google Chrome · Work").
    struct Row: Equatable {
        var label: String
        var value: String
    }

    /// A button of the card.
    struct Button: Equatable {
        enum Role: Equatable { case primary, normal, cancel }
        var id: CookieImportCardAction
        var title: String
        var role: Role
        var isEnabled = true
    }

    var title: String
    var lead: String
    /// "Requested by: Your Chief “Lawrence's Chief”"; nil once the ask is over.
    var requester: String?
    /// The agent's reason, labeled as its own words; nil once the ask is over.
    var reason: String?
    var latest: String?
    var rows: [Row]
    /// The every-site warning, nil for a site list.
    var warning: String?
    /// What macOS asks next and what to choose, or what is happening now.
    var note: String?
    var buttons: [Button]

    init(_ request: CookieImportRequest, phase: CookieImportPhase, isArmed: Bool, showsSites: Bool, deadlineSeconds: Int) {
        let sites = Self.sites(request.domains)
        let fromRow = Row(label: CookieImportStrings.fromLabel, value: request.source)
        let intoRow = Row(label: CookieImportStrings.intoLabel, value: request.target)
        let sitesRow = Row(label: CookieImportStrings.sitesLabel, value: sites)
        requester = nil
        reason = nil
        latest = nil
        warning = nil
        switch phase {
        case .asking:
            title = Self.askTitle(request.requester)
            lead = CookieImportStrings.lead(browser: request.source, target: request.target)
            requester = request.requester.reference
            reason = request.reason
            latest = request.requester.latestMessage.flatMap { $0.isEmpty ? nil : CookieImportText().shown($0, limit: 240) }
            rows = [fromRow, sitesRow, intoRow]
            warning = request.isEverySite ? CookieImportStrings.everySiteWarning : nil
            note = Self.promptNote(request.prompt) + " " + CookieImportStrings.nothingLeaves
            buttons = [Button(id: .deny, title: CookieImportStrings.deny, role: .cancel),
                       Button(id: .allow, title: CookieImportStrings.allowOnce, role: .primary, isEnabled: isArmed)]
            if request.requester.tabID != nil {
                let show = request.requester.kind == .terminal ? CookieImportStrings.showTerminal : CookieImportStrings.showAgentChat
                buttons.insert(Button(id: .showRequester, title: show, role: .normal), at: 0)
            }
            note = (note ?? "") + " " + CookieImportStrings.deadline(deadlineSeconds)
        case .reading:
            title = CookieImportStrings.readingTitle(request.source)
            lead = Self.readingNote(request.prompt)
            rows = [fromRow, sitesRow, intoRow]
            note = nil
            buttons = []
        case .imported(let record):
            title = CookieImportStrings.importedTitle(count: record.report?.written ?? 0, browser: request.source)
            lead = CookieImportStrings.importedLead(target: request.target)
            rows = [Row(label: CookieImportStrings.sitesLabel, value: Self.importedSites(record, all: showsSites))]
            if let report = record.report, report.rejected + report.undecryptable + report.partitioned > 0 {
                note = CookieImportStrings.skipped(report.rejected + report.undecryptable + report.partitioned)
            } else {
                note = nil
            }
            buttons = [Button(id: .remove, title: CookieImportStrings.remove, role: .normal),
                       Button(id: .showAll, title: CookieImportStrings.showAll, role: .normal),
                       Button(id: .dismiss, title: CookieImportStrings.done, role: .primary)]
            if record.sites.count > Self.siteLimit, !showsSites {
                buttons.insert(Button(id: .showSites, title: CookieImportStrings.showSites(record.sites.count), role: .normal), at: 0)
            }
        case .ended(let text):
            title = CookieImportStrings.endedTitle
            lead = text
            rows = []
            note = nil
            buttons = [Button(id: .dismiss, title: CookieImportStrings.done, role: .primary)]
        case .removed(let record):
            title = CookieImportStrings.removedTitle
            lead = CookieImportStrings.removedLead(count: record.cookies.count, target: request.target)
            rows = []
            note = nil
            buttons = [Button(id: .dismiss, title: CookieImportStrings.done, role: .primary)]
        }
    }

    /// The most sites a finished card names before "Show all".
    static let siteLimit = 8

    /// The whole card as text, for a host that draws only text (an agent chat's tool card).
    var plainText: String {
        var lines = [title, lead]
        if let requester { lines.append(CookieImportStrings.requestedBy + ": " + requester) }
        if let reason { lines.append(CookieImportStrings.reasonLabel + ": “" + reason + "”") }
        lines += rows.map { $0.label + ": " + $0.value }
        if let warning { lines.append("⚠︎ " + warning) }
        if let note { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    private static func askTitle(_ requester: CookieImportRequester) -> String {
        switch requester.kind {
        case .homeChief: CookieImportStrings.titleChief
        case .terminal, .unknown: CookieImportStrings.titleProgram
        case .agentChat: CookieImportStrings.title
        }
    }

    private static func sites(_ domains: [String]) -> String {
        guard !domains.isEmpty else { return CookieImportStrings.allSites }
        let shown = domains.prefix(CookieImportText.siteLimit).joined(separator: ", ")
        let more = domains.count - CookieImportText.siteLimit
        return more > 0 ? CookieImportStrings.andMore(shown, more) : shown
    }

    private static func importedSites(_ record: CookieImportRecord, all: Bool) -> String {
        let sites = record.sites
        guard !sites.isEmpty else { return CookieImportStrings.noSites }
        let shown = (all ? sites : Array(sites.prefix(siteLimit))).map { CookieImportStrings.siteCount($0.host, $0.count) }
        let more = sites.count - shown.count
        return more > 0 ? CookieImportStrings.andMore(shown.joined(separator: ", "), more) : shown.joined(separator: ", ")
    }

    private static func promptNote(_ prompt: CookieImportRequest.Prompt) -> String {
        switch prompt {
        case .keychain(let service): CookieImportStrings.afterAllowKeychain(service)
        case .fullDiskAccess: CookieImportStrings.afterAllowSafari
        case .none: CookieImportStrings.afterAllowNone
        }
    }

    private static func readingNote(_ prompt: CookieImportRequest.Prompt) -> String {
        switch prompt {
        case .keychain(let service): CookieImportStrings.readingKeychain(service)
        case .fullDiskAccess: CookieImportStrings.readingSafari
        case .none: CookieImportStrings.readingPlain
        }
    }
}
