import CmuxNextDesign
import CmuxNextResources
import Foundation

/// What a tab's hover card says, row by row (Leo 2026-10-14: like a browser's tab preview,
/// with its memory): the title; where the tab is (a page's host, a folder and branch); what
/// it is doing, for how long, and the agent's model; the program's own status words; and its
/// memory, or that the page is hibernated and what it was using. Each row but the title is
/// optional, so a quiet tab's card stays two or three lines. Pure.
struct TabHoverCardLines: Equatable {
    var title: String
    var place: String?
    var status: String?
    var detail: String?
    var memory: String?

    /// CPU of at least half a core is worth naming next to the memory; less is noise.
    static let notableCPU = 0.5

    /// `report` is the tab's latest sample, or for a hibernated page the last one before it
    /// hibernated.
    static func make(_ item: TabItem, report: ResourceReport?, now: Date) -> Self {
        let facts = item.hover
        // A folder the title already names (a shell at `~` titled `~`) is said once.
        let folder = item.subtitle == item.title ? nil : item.subtitle
        let where_ = facts.kind == .browser ? item.subtitle.flatMap(host) : [folder, facts.branch].compactMap(\.self).nilIfEmpty
        let badges = [item.profileBadge.map { Strings.browserProfile($0.name) }, item.machineBadgeHelp,
                      item.themeBadge.map { Strings.axTheme($0.name) }, where_]
        return TabHoverCardLines(
            title: title(item),
            place: badges.compactMap(\.self).nilIfEmpty,
            status: status(facts, now: now) ?? exitStatus(item) ?? output(facts, now: now),
            detail: item.statusDetail.flatMap { $0.isEmpty ? nil : $0 },
            memory: memory(item, report: report)
        )
    }

    /// The tab's title; a blank page's address is no title (Leo 2026-10-19: "about:blank").
    static func title(_ item: TabItem) -> String {
        if item.title.isEmpty || (item.hover.kind == .browser && isBlank(item.title)) { return Strings.untitled }
        return item.title
    }

    /// An `about:` address (`about:blank`), which names no page.
    static func isBlank(_ address: String) -> Bool { address.lowercased().hasPrefix("about:") }

    /// The color of what the tab is doing (its status row's dot), nil when it reports nothing.
    static func tone(_ item: TabItem) -> HoverCardTone? {
        switch item.hover.activity {
        case .working?, .running?: return .working
        case .needsInput?: return .attention
        case .failed?: return .danger
        case .idle?: return .secondary
        case nil: break
        }
        switch item.status {
        case .failure: return .danger
        case .success: return .success
        case .needsInput: return .attention
        case .none: return item.hover.lastOutput == nil ? nil : .secondary
        }
    }

    /// The card's rows below the title, in order.
    var rows: [String] { [place, status, detail, memory].compactMap(\.self) }

    /// "Working · 3m · Opus 5.5", "Running · 12s" (the command is the title already); nil for
    /// a tab doing nothing it reports.
    static func status(_ facts: TabHoverFacts, now: Date) -> String? {
        let word: String? = switch facts.activity {
        case .working: Strings.hoverWorking
        case .needsInput: Strings.axNeedsInput
        case .idle: Strings.hoverIdle
        case .failed: Strings.axFailure
        case .running: Strings.axBusy
        case nil: nil
        }
        let duration: String? = word == nil ? nil : facts.since.map { Self.elapsed(since: $0, now: now) }
        return [word, duration, facts.model].compactMap(\.self).nilIfEmpty
    }

    /// Output this recent reads as "Output · 12s"; older, the shell reads as "Idle · 5m".
    static let recentOutput: TimeInterval = 60

    /// A plain shell at its prompt (Leo 2026-10-21): "Output · 12s" when it printed under
    /// `recentOutput` ago, "Idle · 5m" after; nil without a prompt and last output.
    static func output(_ facts: TabHoverFacts, now: Date) -> String? {
        guard let at = facts.lastOutput else { return nil }
        let word = now.timeIntervalSince(at) < recentOutput ? Strings.hoverOutput : Strings.hoverIdle
        return [word, elapsed(since: at, now: now)].nilIfEmpty
    }

    /// A terminal whose last command ended: "Done" or "Failed" (its exit status), nil otherwise.
    static func exitStatus(_ item: TabItem) -> String? {
        guard item.hover.kind == .terminal else { return nil }
        switch item.status {
        case .success: return Strings.axSuccess
        case .failure: return Strings.axFailure
        case .none, .needsInput: return nil
        }
    }

    /// "Memory 106 MB" (with the CPU when notable); for a hibernated page "Hibernated", with
    /// what it was using when a measured sample from before is known; a dash until the first
    /// sample; nil when the tab's numbers cannot be had (a remote chat, a page whose renderer
    /// was not matched or is shared with another tab, a terminal its daemon did not report).
    static func memory(_ item: TabItem, report: ResourceReport?) -> String? {
        let tab = report?.tabs.first { $0.id == item.id.rawValue }
        if item.isDormant {
            guard let tab, measured(tab), tab.usage.memoryBytes > 0 else { return Strings.hoverHibernated }
            return Strings.hoverHibernatedWasUsing(ResourceFormat.memory(tab.usage.memoryBytes))
        }
        guard let tab else { return item.hover.kind == .other ? nil : Strings.hoverMemory("–") }
        // Nothing measured: no row, never "Zero KB" or the app-side terminal estimate alone.
        guard measured(tab) else { return nil }
        let memory = ResourceFormat.memory(tab.usage.memoryBytes)
        if let cpu = tab.usage.cpu, cpu >= notableCPU { return Strings.hoverMemoryCPU(memory, ResourceFormat.cpu(cpu)) }
        return Strings.hoverMemory(memory)
    }

    /// Whether a sample measured the tab's own processes (not only an app-side estimate).
    static func measured(_ tab: TabResourceReport) -> Bool { tab.available && tab.processCount > 0 }

    /// A page address's host ("cmux.com"); a local file's path from home ("~/Docs/a.html");
    /// the text itself otherwise.
    static func host(_ address: String) -> String? {
        if isBlank(address) { return nil }
        if let url = URL(string: address), url.isFileURL {
            return (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        }
        guard let host = URL(string: address)?.host(), !host.isEmpty else { return address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter
    }()

    /// "12s", "3m", "2h"; at least a second, also for a start ahead of this clock.
    static func elapsed(since date: Date, now: Date) -> String {
        elapsedFormatter.string(from: max(1, now.timeIntervalSince(date).rounded(.down))) ?? ""
    }
}

private extension Array where Element == String {
    /// The parts joined with " · ", nil when there are none.
    var nilIfEmpty: String? {
        let parts = filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
