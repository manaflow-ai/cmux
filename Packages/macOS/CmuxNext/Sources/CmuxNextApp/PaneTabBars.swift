import Foundation
import Observation

/// Whether a pane shows its horizontal tab bar (cx-soza). Every pane, agent
/// chats and the chat dock included, shows it: the only way to hide one is
/// Hide Tab Bar in the command palette or the pane's menu (Lawrence
/// 2026-10-15, cx-v4dmy, cx-5425v). The retired `tabs.tabBar.<kind>`
/// settings are no longer read.
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

    /// Pane `paneKey`'s own choice: hidden (false), or none (shown). An older
    /// saved `true` reads as shown too.
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

extension PaneController {
    /// Whether the pane hides its tab bar now: only when the person hid it.
    var hidesTabBar: Bool { services.paneTabBars.choice(for: paneKey) == false }
}
