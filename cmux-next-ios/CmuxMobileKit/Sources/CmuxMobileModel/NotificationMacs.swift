import Foundation

extension AppStore {
    /// The account's Macs, once each, for Settings → Notifications' per-Mac switches.
    public var notificationMacs: [MacDevice] {
        var seen = Set<String>()
        return teams.flatMap(\.macs).filter { seen.insert($0.id).inserted }
            .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
    }
}
