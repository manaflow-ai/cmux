import CmuxNextDesign
import Foundation
import Observation

/// Which workspaces show their tabs as a vertical list (Leo 2026-10-20: "a per-workspace Vertical tabs
/// option, off by default, and a Use vertical tabs for all workspaces control"). A workspace's own
/// choice (Turn On / Turn Off Vertical Tabs in its tab bar's menu) wins; a workspace with none follows
/// `tabs.verticalTabs` (Use Vertical Tabs for All Workspaces). Kept per workspace id in `defaults`, like
/// Hide Tab Bar per pane (``PaneTabBarChoices``), so it survives a relaunch.
///
/// Also holds whether vertical lists are collapsed to icons (Collapse Tabs), one choice for every
/// workspace, as Chrome keeps one per window.
@Observable
final class WorkspaceVerticalTabs {
    /// The app's choices (one per app, like `DesignSettings.shared`); tests make their own.
    static let shared = WorkspaceVerticalTabs()
    /// The workspaces remembered, newest last; older choices are dropped.
    static let maximumWorkspaces = 512
    private static let defaultsKey = "workspaces.verticalTabs"
    private static let collapsedKey = "tabs.verticalTabsCollapsed"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var choices: [String: Bool] = [:]
    @ObservationIgnored private var order: [String] = []
    /// Vertical tab lists show icons only (Collapse Tabs / Expand Tabs).
    private(set) var isCollapsed: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCollapsed = defaults.bool(forKey: Self.collapsedKey)
        for entry in defaults.array(forKey: Self.defaultsKey) as? [[String: Any]] ?? [] {
            guard let workspace = entry["workspace"] as? String, let value = entry["vertical"] as? Bool, choices[workspace] == nil else { continue }
            choices[workspace] = value
            order.append(workspace)
        }
    }

    /// Workspace `id`'s own choice; nil when it follows `tabs.verticalTabs`.
    func choice(for id: String) -> Bool? { choices[id] }

    /// Whether workspace `id` shows vertical tabs, with `allWorkspaces` the `tabs.verticalTabs` value.
    func isVertical(_ id: String?, allWorkspaces: Bool = DesignSettings.shared.verticalTabs) -> Bool {
        id.flatMap { choices[$0] } ?? allWorkspaces
    }

    /// Sets workspace `id`'s own choice. A choice equal to `allWorkspaces` is no choice: the workspace
    /// then follows the setting when it changes later.
    func set(_ vertical: Bool, for id: String, allWorkspaces: Bool = DesignSettings.shared.verticalTabs) {
        let value: Bool? = vertical == allWorkspaces ? nil : vertical
        guard choices[id] != value else { return }
        order.removeAll { $0 == id }
        choices[id] = value
        if value != nil { order.append(id) }
        while order.count > Self.maximumWorkspaces { choices[order.removeFirst()] = nil }
        defaults.set(order.compactMap { workspace in choices[workspace].map { ["workspace": workspace, "vertical": $0] as [String: Any] } },
                     forKey: Self.defaultsKey)
    }

    /// Use Vertical Tabs for All Workspaces turned on or off: every workspace's own choice goes, so each
    /// one shows what the person just picked.
    func clearChoices() {
        guard !choices.isEmpty else { return }
        choices = [:]
        order = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        defaults.set(collapsed, forKey: Self.collapsedKey)
    }
}
