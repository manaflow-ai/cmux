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

    static var liveNobody: String { String(localized: "sidebar.live.menu.none", defaultValue: "No one else is live", bundle: .localizedModule) }
    static var liveTurnOff: String { String(localized: "sidebar.live.menu.turnOff", defaultValue: "Turn Live Off", bundle: .localizedModule) }
    static var liveTurnOn: String { String(localized: "sidebar.live.menu.turnOn", defaultValue: "Turn Live On", bundle: .localizedModule) }
    static var liveAgents: String { String(localized: "sidebar.live.menu.agents", defaultValue: "Agents", bundle: .localizedModule) }
    static var liveTeammates: String { String(localized: "sidebar.live.menu.teammates", defaultValue: "Teammates", bundle: .localizedModule) }
}
