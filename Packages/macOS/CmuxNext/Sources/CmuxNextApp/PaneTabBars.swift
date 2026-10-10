import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Observation

/// Whether a pane shows its horizontal tab bar (cx-soza): the pane's own
/// Show Tab Bar choice, else its kind's `tabs.tabBar.<kind>`, whose
/// Automatic is the chat rule (``ChatDockChrome``: the chat dock and a lone
/// chat hide it until they hold two tabs). Cmd-T follows it: a pane that
/// shows its tab bar gets a tab, one that hides it a new workspace.
@Observable
final class PaneTabBarChoices {
    /// The panes remembered, newest last; older choices are dropped.
    static let maximumPanes = 512
    private static let defaultsKey = "panes.tabBar"
    @ObservationIgnored private let defaults: UserDefaults
    private var shown: [String: Bool] = [:]
    @ObservationIgnored private var order: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for entry in defaults.array(forKey: Self.defaultsKey) as? [[String: Any]] ?? [] {
            guard let pane = entry["pane"] as? String, let value = entry["shown"] as? Bool, shown[pane] == nil else { continue }
            shown[pane] = value
            order.append(pane)
        }
    }

    /// Pane `paneKey`'s own choice: shown, hidden, or none (its kind decides).
    func choice(for paneKey: String) -> Bool? { shown[paneKey] }

    func set(_ value: Bool?, for paneKey: String) {
        guard shown[paneKey] != value else { return }
        order.removeAll { $0 == paneKey }
        shown[paneKey] = value
        if value != nil { order.append(paneKey) }
        while order.count > Self.maximumPanes { shown[order.removeFirst()] = nil }
        defaults.set(order.compactMap { pane in shown[pane].map { ["pane": pane, "shown": $0] as [String: Any] } },
                     forKey: Self.defaultsKey)
    }
}

enum PaneTabBar {
    /// Whether the pane hides its tab bar: its own choice, else its kind's
    /// mode, whose Automatic is `automatic` (the chat rule).
    static func hides(choice: Bool?, mode: PaneTabBarMode, automatic: () -> Bool) -> Bool {
        if let choice { return !choice }
        switch mode {
        case .always: return false
        case .never: return true
        case .auto: return automatic()
        }
    }

    /// The pane's kind for its default: agent chats only, browsers only
    /// (New Tab pages count as neither), anything else a terminal pane.
    static func kind(_ tabs: [(isChat: Bool, isBrowser: Bool, isPage: Bool)]) -> PaneTabBarKind {
        let held = tabs.filter { !$0.isPage }
        if !held.isEmpty, held.allSatisfy({ $0.isChat }) { return .agent }
        if !held.isEmpty, held.allSatisfy({ $0.isBrowser && !$0.isChat }) { return .browser }
        return .terminal
    }
}

extension PaneController {
    /// The pane's kind for `tabs.tabBar.<kind>`.
    var tabBarKind: PaneTabBarKind {
        let agentTabs = services.agentTabs
        let tabs = pane.tabs.filter { !pendingClosed.contains($0.id) }.map { tab in
            (isChat: ChatColumnPlacement.isChat(tab, services: services), isBrowser: tab.kind == .browser,
             isPage: agentTabs.isNewTabPage(tab.id))
        } + (state?.localBrowserTabs[paneKey] ?? []).map { _ in (isChat: false, isBrowser: true, isPage: false) }
        return PaneTabBar.kind(tabs)
    }

    /// Whether the pane hides its tab bar now, holding `tabCount` tabs.
    func hidesTabBar(tabCount: Int) -> Bool {
        let mode = (services.settings?.snapshot.paneTabBars ?? PaneTabBarDefaults())[tabBarKind]
        return PaneTabBar.hides(choice: services.paneTabBars.choice(for: paneKey), mode: mode) {
            ChatDockChrome.hidesStrip(self, tabCount: tabCount)
        }
    }
}
