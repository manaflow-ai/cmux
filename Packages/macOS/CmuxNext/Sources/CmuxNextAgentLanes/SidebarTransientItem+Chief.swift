public import CmuxNextAgentActivity
public import CmuxNextDesign
public import CmuxNextSidebar
import Foundation

/// The Chief in the sidebar (Leo 2026-10-20: talk to the Chief from the left side, next to the
/// workspaces, not only through Home). The Chief item is the `chief` built-in (off by default; Add
/// to Sidebar adds it, and it drags like any item); this reads its status from
/// the Chief home's acpmux and draws its subagents in client-only indented rows right under it.
///
/// The Chief's acpmux (`ChatsFeed.chiefTurnStates`) names its sessions by role: a turn is
/// `optchat-<home>-<n>`, a subagent `optchat-sub-<home>-a<n>`, a compactor `optchat-compact-…`.
/// The Chief needs you while any of its turns waits on a permission or question, works while one
/// runs, and is idle otherwise. Folded, the subagent rows hide only the idle ones: a working,
/// waiting, failed or lost subagent always shows, so the list never folds away an active one.
extension SidebarTransientItem {
    private static let chiefSubagentPrefix = LayoutItemID.transientPrefix + "chief-sub:"

    /// The Chief subagent session a subagent row opens; nil for any other item.
    public static func chiefSubagentSession(_ id: LayoutItemID) -> String? {
        id.rawValue.hasPrefix(chiefSubagentPrefix) ? String(id.rawValue.dropFirst(chiefSubagentPrefix.count)) : nil
    }

    /// The Chief item's indicator and badge (the subagents that need a person).
    public static func chiefStatus(lanes: some Collection<AgentActivityLane>) -> (activity: StatusIndicatorState, badge: Int?) {
        let turns = lanes.filter { ChiefSessionRole(name: $0.name) == .turn }
        let attention = lanes.count(where: { ChiefSessionRole(name: $0.name) == .subagent && $0.needsAttention })
        return (chiefActivity(turns: turns), attention > 0 ? attention : nil)
    }

    /// The subagent rows under the Chief item, in order; none draw while the item is not in the
    /// sidebar. `showsIdle`: the list is unfolded, so idle subagents show too.
    @MainActor
    public static func chiefSubagents(lanes: some Collection<AgentActivityLane>, showsIdle: Bool) -> [SidebarTransientItem] {
        let subagents = lanes.filter { ChiefSessionRole(name: $0.name) == .subagent }
            .sorted { ($0.subagentNumber ?? .max, $0.name) < ($1.subagentNumber ?? .max, $1.name) }
        var items: [SidebarTransientItem] = []
        var previous = LayoutItemRef.builtIn(.chief)
        for lane in subagents where showsIdle || lane.state != .idle {
            var row = SidebarItemInfo(title: lane.subagentTitle, symbol: "person.crop.circle", brand: lane.harness)
            row.activity = activity(of: lane.state)
            row.indent = 1
            // Each row draws right after the one before it, so the list keeps its order under the Chief.
            let item = SidebarTransientItem(id: LayoutItemID(chiefSubagentPrefix + lane.id), info: row, after: [previous], anchoredOnly: true)
            previous = item.item.ref
            items.append(item)
        }
        return items
    }

    /// The Chief's status from its turns: waiting on you over working over idle. Only the newest
    /// turn's failure shows; an older turn that failed is history, not the Chief's state now.
    static func chiefActivity(turns: [AgentActivityLane]) -> StatusIndicatorState {
        if turns.contains(where: { $0.state == .input }) { return .waiting }
        if turns.contains(where: { $0.state == .working }) { return .working }
        let newest = turns.max { ($0.turnNumber ?? -1) < ($1.turnNumber ?? -1) }
        return newest.map { activity(of: $0.state) } ?? .idle
    }

    static func activity(of state: AgentActivityLane.State) -> StatusIndicatorState {
        switch state {
        case .working: .working
        case .input: .waiting
        case .failed, .lost: .error
        case .idle: .idle
        }
    }
}

/// What a session on the Chief's acpmux is, read from its name (optchat-chief's naming).
nonisolated enum ChiefSessionRole: Equatable {
    case turn, subagent, other

    init(name: String) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.first == "optchat", parts.count >= 3 else { self = .other; return }
        if parts[1] == "sub" { self = .subagent; return }
        // `optchat-<home>-<n>`, or `-<n>-<m>` when acpmux deduped a taken name (optchat-chief's
        // `is_turn_name`): a turn; `optchat-compact-…` and the rest are not.
        let numbers = parts.dropFirst(2)
        self = parts[1] != "compact" && numbers.count <= 2 && numbers.allSatisfy { Int($0) != nil } ? .turn : .other
    }
}

extension AgentActivityLane {
    /// A turn session's number (`optchat-<home>-<n>`, `-<m>` after it when acpmux deduped the name).
    nonisolated var turnNumber: Int? {
        let parts = name.split(separator: "-")
        return parts.count > 2 ? Int(parts[2]) : nil
    }

    /// A subagent's number (`optchat-sub-<home>-a<n>`, `-<m>` after it when acpmux deduped the name).
    nonisolated var subagentNumber: Int? {
        let parts = name.split(separator: "-")
        guard parts.count > 3, parts[3].first == "a" else { return nil }
        return Int(parts[3].dropFirst())
    }

    /// The subagent's task title (acpmux's title when it has one of its own), else "Subagent":
    /// its `a7` id is the Chief's to use, never shown (Leo 2026-10-21).
    nonisolated var subagentTitle: String {
        guard title != name, let task = title.chiefTaskTitle else { return ChiefToolStrings.subagent }
        return task
    }
}

/// The chat links of the Chief's subagents, by id (`a459` to `cmux://chief/<home>/session/<id>`),
/// for Home to link every bare mention of one in any Chief's reply (MessagesLabHome's
/// `HomeSubagentLinks`; Lawrence 2026-10-22: "why did u forget to link a459"). Read from the Chief
/// home's acpmux lanes: a subagent session is named `optchat-sub-<home>-a<n>` and tagged
/// `mux.parent = optchat-chief:<home>`. This Mac's own lane wins over a peer's mirror of the same
/// id; between two sessions of one id (acpmux deduped the name: a restarted subagent) the newer.
public enum ChiefSubagentLinks {
    public nonisolated static func links(lanes: some Collection<AgentActivityLane>) -> [String: String] {
        var best: [String: AgentActivityLane] = [:]
        for lane in lanes where ChiefSessionRole(name: lane.name) == .subagent {
            guard let number = lane.subagentNumber, number > 0, home(of: lane) != nil, token(lane.id) else { continue }
            let id = "a\(number)"
            if let have = best[id], !newer(lane, than: have) { continue }
            best[id] = lane
        }
        return best.reduce(into: [:]) { out, entry in
            if let home = home(of: entry.value) { out[entry.key] = "cmux://chief/\(home)/session/\(entry.value.id)" }
        }
    }

    /// The Chief home id (8 lowercase hex digits) of a subagent lane: its `mux.parent` tag, else
    /// its name's `<home>` part.
    nonisolated static func home(of lane: AgentActivityLane) -> String? {
        let tagged = lane.parent.flatMap { $0.hasPrefix("optchat-chief:") ? String($0.dropFirst("optchat-chief:".count)) : nil }
        let named = lane.name.split(separator: "-").dropFirst(2).first.map(String.init)
        return [tagged, named].compactMap { $0 }.first { home in
            home.utf8.count == 8 && home.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    /// A session id the link may carry (optchat-chief `subagent_link`'s token rule).
    nonisolated static func token(_ s: String) -> Bool {
        (1...200).contains(s.utf8.count) && s.utf8.allSatisfy { b in
            (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 45 || b == 95 || b == 46
        }
    }

    /// `lane` should name the id over `other`: this Mac's over a peer's, then the newer session.
    nonisolated static func newer(_ lane: AgentActivityLane, than other: AgentActivityLane) -> Bool {
        if (lane.peer == nil) != (other.peer == nil) { return lane.peer == nil }
        return (lane.createdAt ?? .distantPast) > (other.createdAt ?? .distantPast)
    }
}
