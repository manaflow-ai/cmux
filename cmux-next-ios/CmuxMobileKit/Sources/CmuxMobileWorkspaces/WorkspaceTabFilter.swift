import CmuxMobileModel
import Foundation

/// Which of a workspace's tabs the tab grid lists (Leo, 2026-11-23: "we want a
/// motherfucking filtering mechanism for only agent sessions, agent sessions/terminals,
/// and fucking browsers on their own honestly should be a fucking toggle").
///
/// One choice for every workspace on this phone, kept across launches. `all` is the
/// default, so nobody's grid changes until they pick a filter.
public enum WorkspaceTabFilter: String, CaseIterable, Sendable, Codable {
    case all
    /// Agent chats only.
    case agents
    /// Agent chats and terminals: the work, without the web.
    case agentsAndTerminals
    /// Browser tabs (and streamed simulators, which draw like one) on their own.
    case browsers

    public var title: String {
        switch self {
        case .all: String(localized: "All Tabs")
        case .agents: String(localized: "Agents")
        case .agentsAndTerminals: String(localized: "Agents & Terminals")
        case .browsers: String(localized: "Browsers")
        }
    }

    public var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .agents: "bubble.left.and.text.bubble.right"
        case .agentsAndTerminals: "terminal"
        case .browsers: "safari"
        }
    }

    /// Whether a tab of this kind is listed.
    public func lists(_ kind: WorkspaceTab.Kind) -> Bool {
        switch self {
        case .all: true
        case .agents: kind == .agent
        case .agentsAndTerminals: kind == .agent || kind == .terminal
        case .browsers: kind == .browser || kind == .simulator
        }
    }

    /// The tabs the grid lists, in order. `keeping` (the tab on screen) is always listed,
    /// whatever its kind: the page zooms out to its own card, and the grid never loses
    /// the tab you came from.
    public func listed(_ tabs: [WorkspaceTab], keeping kept: Set<String>) -> [WorkspaceTab] {
        guard self != .all else { return tabs }
        return tabs.filter { lists($0.kind) || kept.contains($0.id) }
    }

    /// How many tabs a filter hides, for the header's count ("3 of 9 tabs").
    public func hiddenCount(_ tabs: [WorkspaceTab], keeping kept: Set<String>) -> Int {
        tabs.count - listed(tabs, keeping: kept).count
    }

    static let defaultsKey = "cmux.mobile.workspaceTabFilter"

    /// The saved choice (`all` when none or unreadable).
    public static func saved(_ defaults: UserDefaults = .standard) -> WorkspaceTabFilter {
        defaults.string(forKey: defaultsKey).flatMap(WorkspaceTabFilter.init(rawValue:)) ?? .all
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
