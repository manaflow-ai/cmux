import CmuxMobileDesign
import Foundation

/// One piece of a session's quiet metadata, as acpmux sends it on the session summary
/// (`composerStatus.facts[]`, cmux-tui acpmux `protocol/composer_status.rs` `FooterFact`): RFD 0130,
/// "What else belongs in the composer footer". acpmux decides which facts exist and which are
/// `live` (worth a counter in the footer itself); the phone only draws them, as the Mac's pane does
/// (`webviews/src/agent-session/acpmux/composerStatusModel.ts`).
public struct AgentFooterFact: Hashable, Sendable {
    /// `FactKind`, in acpmux's footer order.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case machine, folder, branch, harness, model, context, turn, subagents, queued

        /// Its text repeats one of the session row's own fields: a census row leaves it out
        /// (`FactKind::repeats_row`), so a row without it says nothing about it.
        var repeatsRow: Bool { [.machine, .folder, .branch, .harness, .model].contains(self) }
    }

    public var kind: Kind
    public var text: String?
    public var count: Int?
    /// The share of the context window used, 0 to 1.
    public var fraction: Double?
    /// The running turn's start.
    public var since: Date?
    /// Worth a counter in the footer row itself now.
    public var live: Bool
    /// Worth its words at rest (the machine of a chat on another machine).
    public var atRest: Bool

    public init(kind: Kind, text: String? = nil, count: Int? = nil, fraction: Double? = nil, since: Date? = nil,
                live: Bool = false, atRest: Bool = false) {
        self.kind = kind
        self.text = text
        self.count = count
        self.fraction = fraction
        self.since = since
        self.live = live
        self.atRest = atRest
    }

    /// A fact as acpmux sent it; nil for a kind this phone does not know (a newer acpmux).
    public init?(_ value: JSONValue) {
        guard let raw = value["kind"]?.stringValue, let kind = Kind(rawValue: raw) else { return nil }
        self.kind = kind
        text = value["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        count = value["count"]?.numberValue.map { Int($0) }
        fraction = value["fraction"]?.numberValue.map { min(1, max(0, $0)) }
        since = value["since"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        live = value["live"] == .bool(true)
        atRest = value["atRest"] == .bool(true)
    }

    /// A counter's number as the footer draws it: "9+" past nine, so its slot never widens.
    public var countLabel: String {
        guard let count else { return "" }
        return count > 9 ? "9+" : "\(count)"
    }

    /// The SF Symbol a live counter draws beside its number.
    public var symbol: String {
        switch kind {
        case .subagents: "person.2"
        case .queued: "tray.full"
        case .machine: "desktopcomputer"
        case .folder: "folder"
        case .branch: "arrow.triangle.branch"
        case .harness: "terminal"
        case .model: "cpu"
        case .context: "gauge.with.needle"
        case .turn: "clock"
        }
    }

    /// The card row's label.
    public var label: String {
        switch kind {
        case .machine: String(localized: "mobile.agentChat.footerFacts.machine", defaultValue: "Machine", bundle: .module)
        case .folder: String(localized: "mobile.agentChat.footerFacts.folder", defaultValue: "Folder", bundle: .module)
        case .branch: String(localized: "mobile.agentChat.footerFacts.branch", defaultValue: "Branch", bundle: .module)
        case .harness: String(localized: "mobile.agentChat.footerFacts.harness", defaultValue: "Harness", bundle: .module)
        case .model: String(localized: "mobile.agentChat.footerFacts.model", defaultValue: "Model", bundle: .module)
        case .context: String(localized: "mobile.agentChat.footerFacts.context", defaultValue: "Context", bundle: .module)
        case .turn: String(localized: "mobile.agentChat.footerFacts.turn", defaultValue: "Turn", bundle: .module)
        case .subagents: String(localized: "mobile.agentChat.footerFacts.subagents", defaultValue: "Subagents", bundle: .module)
        case .queued: String(localized: "mobile.agentChat.footerFacts.queued", defaultValue: "Queued", bundle: .module)
        }
    }

    /// The card row's value at `now` (the turn's elapsed time moves); nil when it has nothing to say.
    public func value(now: Date) -> String? {
        switch kind {
        case .folder: return text.map(Self.lastTwoSegments)
        case .machine, .branch, .harness, .model: return text
        case .context: return fraction.map { "\(Int(($0 * 100).rounded()))%" }
        case .turn: return since.map { Self.elapsed(now.timeIntervalSince($0)) }
        case .subagents:
            return count.map { String(localized: "mobile.agentChat.footerFacts.running", defaultValue: "\($0) running", bundle: .module) }
        case .queued:
            return count.map { String(localized: "mobile.agentChat.footerFacts.waiting", defaultValue: "\($0) waiting", bundle: .module) }
        }
    }

    /// A folder's last two segments (RFD 0130: "folder (last two segments; the full path on hover)").
    static func lastTwoSegments(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2 else { return path }
        return parts.suffix(2).joined(separator: "/")
    }

    /// "42s", "3m 05s", "1h 02m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

/// A session's footer facts (`composerStatus.facts`), in acpmux's order.
public struct AgentFooterFacts: Hashable, Sendable {
    public var facts: [AgentFooterFact]

    public init(_ facts: [AgentFooterFact] = []) { self.facts = facts }

    /// The facts of a session row's `composerStatus`; none when the row carries no status (a census
    /// row with nothing live, an older acpmux).
    public init(composerStatus: JSONValue?) {
        facts = (composerStatus?["facts"]?.arrayValue ?? []).compactMap(AgentFooterFact.init)
    }

    /// The facts a newer row says, keeping the row-repeating ones (machine, folder, branch,
    /// harness, model) from before when it leaves them all out: a census row does
    /// (`composer_status::census`), and leaving them out says they are unchanged, not gone. The
    /// live counters, context and turn always come from the newer row.
    public func updated(with next: AgentFooterFacts) -> AgentFooterFacts {
        guard !next.facts.contains(where: \.kind.repeatsRow) else { return next }
        let kept = facts.filter(\.kind.repeatsRow)
        let merged = kept + next.facts
        let order = Dictionary(uniqueKeysWithValues: AgentFooterFact.Kind.allCases.enumerated().map { ($1, $0) })
        return AgentFooterFacts(merged.sorted { order[$0.kind, default: 0] < order[$1.kind, default: 0] })
    }

    /// The counters the footer row draws (subagents running, prompts queued).
    public var live: [AgentFooterFact] { facts.filter { $0.live && ($0.count ?? 0) > 0 } }

    public var isEmpty: Bool { facts.isEmpty }
}

/// Where the phone composer shows a session's facts (Settings → Composer → Session Facts), the
/// Mac's experiment `composer-footer-facts` (RFD 0130). Off by default: turning a footer feature on
/// for everyone is Leo's call ("default MAY need a call").
public enum ComposerFooterFactsMode: String, CaseIterable, Sendable {
    /// Nothing new shows, as before.
    case off
    /// Running subagents and queued prompts show as counters beside the context meter; tapping
    /// one (or the meter's info mark) opens the Session card.
    case pulse
    /// No counters: a faint info mark beside the meter opens the Session card.
    case door

    public static let key = CmuxMobilePreferences.Key.composerFooterFacts

    /// The stored mode; `strip` (the Mac's fourth arm) has no phone form: a 390 pt controls row has
    /// no free middle for a metadata line beside the pickers (RFD 0130 goal 3), so it reads as pulse.
    public static func stored(_ raw: String?) -> ComposerFooterFactsMode {
        if raw == "strip" { return .pulse }
        return raw.flatMap(ComposerFooterFactsMode.init(rawValue:)) ?? .off
    }

}
