import Foundation
import Observation

/// Other members' Macs shown by Terminal Sizing after the phone has visited their team.
@MainActor
@Observable
public final class TerminalSizingPeers {
    private let cache: LastKnownList?
    @ObservationIgnored private lazy var restored = cache?.read([String: [MacDevice]].self) ?? [:]
    private var updated: [String: [MacDevice]]?
    private var byTeam: [String: [MacDevice]] { updated ?? restored }

    public init(cache: LastKnownList?) {
        self.cache = cache
    }

    /// A full team response settles that team's peers, including their removal. The caller's
    /// own Macs come from the shared Devices roster instead.
    public func replace(teamID: String, devices: [MacDevice], accountID: String) {
        let peers = devices.filter { $0.ownerUserID != nil && $0.ownerUserID != accountID }
        guard peers != (byTeam[teamID] ?? []) else { return }
        var latest = byTeam
        latest[teamID] = peers.isEmpty ? nil : peers
        updated = latest
        cache?.save(latest)
    }

    public func forget(_ id: String) {
        let affected = byTeam.keys.filter { byTeam[$0]?.contains { $0.id == id } == true }
        guard !affected.isEmpty else { return }
        var latest = byTeam
        for teamID in affected {
            latest[teamID]?.removeAll { $0.id == id }
            if latest[teamID]?.isEmpty == true { latest[teamID] = nil }
        }
        updated = latest
        cache?.save(latest)
    }

    /// Never include a roster whose membership the active account no longer displays.
    public func visible(in teams: [Team]) -> [MacDevice] {
        teams.flatMap { byTeam[$0.id] ?? [] }
    }
}

/// One of the account's devices as Settings → Devices lists it. A phone
/// registers two service devices (link and presence); `ids` holds both, so
/// removing the phone removes them together.
public struct SettingsDevice: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case mac, phone }

    public var id: String { ids.first ?? name }
    public var ids: [String]
    public var kind: Kind
    public var name: String
    /// Live presence for a Mac; nil for a phone.
    public var online: Bool?
    public var lastSeenAt: Date?
    /// When the account first registered it (nil when the list doesn't say).
    public var addedAt: Date?
    public var isThisDevice: Bool
    /// A phone with an APNs token registered.
    public var receivesNotifications: Bool
    /// A Mac's machine id (``MacDevice/machineID``): rows with one are builds of one computer.
    public var machineID: String?
    /// The device kind used by the shared glyph table (nil from older service records).
    public var deviceKind: String?
    /// The team (or personal space) the device is registered in, when known.
    public var teamID: String?

    public init(ids: [String], kind: Kind, name: String, online: Bool?, lastSeenAt: Date?, addedAt: Date? = nil,
                isThisDevice: Bool, receivesNotifications: Bool, machineID: String? = nil, teamID: String? = nil,
                deviceKind: String? = nil) {
        self.machineID = machineID
        self.teamID = teamID
        self.deviceKind = deviceKind
        self.ids = ids
        self.kind = kind
        self.name = name
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.addedAt = addedAt
        self.isThisDevice = isThisDevice
        self.receivesNotifications = receivesNotifications
    }
}

/// The Macs Settings → Devices lists, and the count the Settings root shows
/// next to "Devices": one list for both, so they never disagree.
public enum SettingsDeviceRows {
    /// The Mac rows. With a device service (`hasService`), the service's list
    /// with live presence from `liveMacs` laid over it, or nil while it has not
    /// loaded. Without one, every Mac the phone knows (`liveMacs`, each once).
    /// `teamOf`: each live Mac's team (the fallback's rows carry it).
    public static func macs(service: [SettingsDevice]?, hasService: Bool, liveMacs: [MacDevice],
                            teamOf: [String: String]? = nil) -> [SettingsDevice]? {
        guard hasService else {
            var seen = Set<String>()
            return liveMacs.filter { seen.insert($0.id).inserted }.map {
                SettingsDevice(ids: [$0.id], kind: .mac, name: $0.name, online: $0.isOnline, lastSeenAt: $0.lastSeenAt,
                               isThisDevice: false, receivesNotifications: false, machineID: $0.machineID,
                               teamID: teamOf?[$0.id], deviceKind: $0.deviceKind)
            }
        }
        guard let service else { return nil }
        let live = Dictionary(liveMacs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return service.filter { $0.kind == .mac }.map { device in
            guard let mac = device.ids.lazy.compactMap({ live[$0] }).first else { return device }
            var next = device
            next.online = mac.isOnline
            next.lastSeenAt = mac.lastSeenAt ?? device.lastSeenAt
            next.machineID = device.machineID ?? mac.machineID
            next.deviceKind = device.deviceKind ?? mac.deviceKind
            return next
        }
    }

    /// Terminal sizing keeps team Macs, including another member's, and fills in this
    /// account's own Macs from the same directory as Devices while discovery catches up.
    public static func sizingMacs(teams: [Team], activeTeamID: String, service: [SettingsDevice]?,
                                  accountID: String?, peers: [MacDevice] = []) -> [MacDevice] {
        let restored = (service ?? []).filter { $0.kind == .mac }.map {
            MacDevice(id: $0.id, name: $0.name, isOnline: $0.online == true, lastSeenAt: $0.lastSeenAt,
                      ownerUserID: accountID, machineID: $0.machineID)
        }
        return MacRoster.acrossTeams(teams, activeTeamID: activeTeamID, including: peers + restored)
    }

    /// The phone rows (only a device service lists phones).
    public static func phones(service: [SettingsDevice]?) -> [SettingsDevice] {
        (service ?? []).filter { $0.kind == .phone }
    }

    /// The Settings root's trailing value: the number of Mac rows the page
    /// shows, or nil (no value) while the list has not loaded.
    public static func rootValue(service: [SettingsDevice]?, hasService: Bool, liveMacs: [MacDevice]) -> String? {
        macs(service: service, hasService: hasService, liveMacs: liveMacs).map { "\($0.count)" }
    }
}
