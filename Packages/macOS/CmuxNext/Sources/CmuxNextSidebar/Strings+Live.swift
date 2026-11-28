import Foundation

extension Strings {
    /// The footer Live button's name (VoiceOver, the menu's first words).
    static var live: String { String(localized: "sidebar.live", defaultValue: "Live", bundle: .localizedModule) }

    /// The Live button's tooltip: what it means, the click's effect, and how many teammates are live.
    static func liveTooltip(isLive: Bool, teammatesLive: Int) -> String {
        let state = isLive
            ? String(localized: "sidebar.live.on", defaultValue: "Live is on. Click to turn it off.", bundle: .localizedModule)
            : String(localized: "sidebar.live.off", defaultValue: "Live is off. Click to go live.", bundle: .localizedModule)
        let count = String(localized: "sidebar.live.count", defaultValue: "Teammates live: \(teammatesLive)", bundle: .localizedModule)
        return state + "\n" + count
    }

    /// The sync and presence lines (RFD 0140) the tooltip appends and the menu's first row shows; empty when unknown.
    static func liveStatus(_ status: SidebarLiveState.Status?) -> [String] {
        guard let status else { return [] }
        var lines: [String] = []
        switch status.sync {
        case .synced?: lines.append(String(localized: "sidebar.live.sync.synced", defaultValue: "All changes synced", bundle: .localizedModule))
        case .syncing?:
            let n = Int(clamping: status.pendingEdits)
            lines.append(String(localized: "sidebar.live.sync.syncing", defaultValue: "Syncing changes: \(n)", bundle: .localizedModule))
        case .offline?:
            let n = Int(clamping: status.pendingEdits)
            lines.append(String(localized: "sidebar.live.sync.offline", defaultValue: "Offline. Changes queued: \(n)", bundle: .localizedModule))
        case .alone?: lines.append(String(localized: "sidebar.live.sync.alone", defaultValue: "No other device to sync with yet", bundle: .localizedModule))
        case nil: break
        }
        if status.others > 0 {
            let n = Int(status.others)
            lines.append(String(localized: "sidebar.live.here.others", defaultValue: "Others here: \(n)", bundle: .localizedModule))
        }
        if status.agents > 0 {
            let n = Int(status.agents)
            lines.append(String(localized: "sidebar.live.here.agents", defaultValue: "Agents here: \(n)", bundle: .localizedModule))
        }
        return lines
    }

    static var liveNobody: String { String(localized: "sidebar.live.menu.none", defaultValue: "No one else is live", bundle: .localizedModule) }
    static var liveTurnOff: String { String(localized: "sidebar.live.menu.turnOff", defaultValue: "Turn Live Off", bundle: .localizedModule) }
    static var liveTurnOn: String { String(localized: "sidebar.live.menu.turnOn", defaultValue: "Turn Live On", bundle: .localizedModule) }
    static var liveAgents: String { String(localized: "sidebar.live.menu.agents", defaultValue: "Agents", bundle: .localizedModule) }
    static var liveTeammates: String { String(localized: "sidebar.live.menu.teammates", defaultValue: "Teammates", bundle: .localizedModule) }
}
