public import Foundation
public import Observation

/// Every device that can reach this computer, for Settings > Devices and the Add Device card
/// (plans/cmux-next/add-device-DESIGN.md 2.4-2.6): `cmux device list` (acpmux peers and pairings,
/// remote-hosting logins, the network's computers) plus the phones paired with this Mac, one
/// remove for all of them, and the recent activity from the audit log. It reads only when asked
/// (``refresh()``): the Settings window opening, an add or a remove finishing.
@MainActor @Observable
public final class DeviceDirectory {
    /// The last listing; nil before the first read or when the CLI is missing.
    public private(set) var listing: DeviceListing?
    /// The newest audit lines first.
    public private(set) var activity: [DeviceActivity] = []
    /// Why the last remove or Full-access change failed; nil after a success.
    public private(set) var lastError: String?

    /// Runs `cmux-tui <arguments>` and returns its stdout, nil when it failed.
    @ObservationIgnored private let run: ([String]) async -> Data?
    /// Forgets a phone paired with this Mac (`IPhoneHostService.revokePhone`).
    @ObservationIgnored private let removePhone: (String) async -> Void
    /// Sets a paired client machine's Full-access setting (acpmux `_acpmux/pair_set`, by pairing
    /// id); true when acpmux took it. Nil (tests that never set it): every set fails.
    @ObservationIgnored private let pairSet: ((String, Bool) async -> Bool)?
    /// A removed acpmux peer's `[user@]host`: the app forgets its SSH machine there too, so one
    /// Remove takes the computer out of the sidebar as well (HQ #4877 break 8). Nil: nothing more.
    @ObservationIgnored private let peerRemoved: ((String) async -> Void)?
    @ObservationIgnored private var reading = false

    /// - Parameters:
    ///   - run: The app's own `cmux-tui` run (tests pass fixture JSON).
    ///   - removePhone: The Mac's phone pairing's remove.
    ///   - setFullAccess: acpmux's `pair_set` over a connection proven as the person.
    ///   - peerRemoved: Called with a removed peer's ssh `[user@]host` after its remove succeeded.
    public init(run: @escaping ([String]) async -> Data?, removePhone: @escaping (String) async -> Void,
                setFullAccess: ((String, Bool) async -> Bool)? = nil, peerRemoved: ((String) async -> Void)? = nil) {
        self.run = run
        self.removePhone = removePhone
        pairSet = setFullAccess
        self.peerRemoved = peerRemoved
    }

    /// The id prefix of a phone row (its pairing lives in the Mac app, not in the CLI's stores).
    public static let phonePrefix = "phone:"
    /// The id prefix of an acpmux peer row (`peer:NAME`).
    public static let peerPrefix = "peer:"
    /// The id prefix of an acpmux pairing row, the only kind with a Full-access setting.
    public static let pairedPrefix = "paired:"

    /// The acpmux pairing name of a phone paired with this Mac (acpmux role `phone`). The app's
    /// iPhone host issues the phone's credential under it (`MobileHostPairedDevices.acpmuxRecordName`,
    /// kept equal by a test), so a phone row joins that record for its Full-access setting.
    public static func phoneRecordName(_ phoneID: String) -> String {
        "phone-" + String(phoneID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(74))
    }

    /// Phone `phoneID`'s own acpmux record in the listing (a `phone` row named for it), if any.
    private func phoneRecord(_ phoneID: String) -> DeviceListing.Device? {
        let name = Self.phoneRecordName(phoneID)
        return listing?.devices.first { $0.kind == "phone" && $0.name == name && $0.id.hasPrefix(Self.pairedPrefix) }
    }

    /// Reads the list and the activity again; a read already running makes this a no-op.
    public func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        if let data = await run(["device", "list", "--json"]), let listing = try? DeviceListing.parse(data) {
            self.listing = listing
        }
        if let data = await run(["device", "audit", "--json", "--limit", "8"]), let entries = try? DeviceActivity.parse(data) {
            activity = entries
        }
    }

    /// Reads again and returns the listing (the Add Device card's network way).
    public func read() async -> DeviceListing? {
        await refresh()
        return listing
    }

    /// Removes a device from every store that lets it in, then reads again. Returns the error to
    /// show, nil when it is gone.
    @discardableResult
    public func remove(id: String) async -> String? {
        if id.hasPrefix(Self.phonePrefix) {
            await removePhone(String(id.dropFirst(Self.phonePrefix.count)))
            lastError = nil
            return nil
        }
        // A peer's ssh route is read before the remove takes it out of the list.
        let peer = id.hasPrefix(Self.peerPrefix) && peerRemoved != nil
            ? await sshPeers().first { Self.peerPrefix + $0.name == id } : nil
        let ok = await run(["device", "remove", id, "--yes", "--json"]) != nil
        lastError = ok ? nil : AddDeviceStrings.removeFailed
        if ok, let peer { await peerRemoved?(peer.destination) }
        await refresh()
        return lastError
    }

    /// An acpmux peer this computer dials over ssh: its name and the `[user@]host` its `ssh://` URL
    /// reaches.
    public nonisolated struct SSHPeer: Equatable, Sendable {
        public var name: String
        public var destination: String

        public init(name: String, destination: String) {
            self.name = name
            self.destination = destination
        }
    }

    /// The acpmux peers reached over ssh (`acp host ls --json`); empty when the CLI failed.
    public func sshPeers() async -> [SSHPeer] {
        guard let data = await run(["acp", "host", "ls", "--json"]) else { return [] }
        return Self.sshPeers(data)
    }

    /// The peers of an `acp host ls --json` answer (`{"peers":[{"name","url"},...]}`) whose URL is
    /// `ssh://`.
    public nonisolated static func sshPeers(_ data: Data) -> [SSHPeer] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((object?["peers"] as? [[String: Any]]) ?? []).compactMap { peer in
            guard let name = peer["name"] as? String, !name.isEmpty, let url = peer["url"] as? String,
                  let target = HostCandidate.sshTarget(peerURL: url) else { return nil }
            return SSHPeer(name: name, destination: target.destination)
        }
    }

    /// Removes the acpmux peers `matches` picks by their ssh `[user@]host` (`acp host rm`), then
    /// reads again: a forgotten SSH machine's peer goes with it (HQ #4877 break 8).
    public func removePeers(where matches: (String) -> Bool) async {
        var removed = false
        // The predicate is asked right before each remove, after every await before it.
        for peer in await sshPeers() where matches(peer.destination) {
            _ = await run(["acp", "host", "rm", peer.name, "--json"])
            removed = true
        }
        if removed { await refresh() }
    }

    /// Lets a paired client machine or phone run chats here in Full access, or stops it (at once:
    /// acpmux holds its running chats again), then reads again. Returns the error to show, nil when
    /// set. A phone row sets its own acpmux record, found by kind and name, never by name alone.
    @discardableResult
    public func setFullAccess(id: String, on: Bool) async -> String? {
        let record = id.hasPrefix(Self.phonePrefix) ? phoneRecord(String(id.dropFirst(Self.phonePrefix.count)))?.id : id
        guard let record, record.hasPrefix(Self.pairedPrefix) else { return nil }
        let ok = await pairSet?(String(record.dropFirst(Self.pairedPrefix.count)), on) ?? false
        lastError = ok ? nil : on ? AddDeviceStrings.fullAccessOnFailed : AddDeviceStrings.fullAccessOffFailed
        await refresh()
        return lastError
    }

    /// The rows Settings shows: the CLI's devices, then `phones` (the Mac's paired phones as
    /// `(id, name, connected)`, each with its own acpmux record's Full-access setting), with words
    /// a person reads. A phone's acpmux record is not a row of its own.
    public func rows(phones: [(id: String, name: String, connected: Bool)]) -> [DeviceListRow] {
        var rows = (listing?.devices ?? []).filter { $0.kind != "phone" }.map { device in
            let roles = device.roles.map(AddDeviceStrings.role).joined(separator: ", ")
            return DeviceListRow(id: device.id, title: device.name, subtitle: [roles, AddDeviceStrings.state(device.state)].filter { !$0.isEmpty }.joined(separator: " · "),
                             detail: device.detail, state: device.state, removable: true, fullAccess: device.fullAccess,
                             fullAccessHelp: device.fullAccess == nil ? nil : AddDeviceStrings.fullAccessHelp)
        }
        rows += phones.map { phone in
            let fullAccess = phoneRecord(phone.id)?.fullAccess
            return DeviceListRow(id: Self.phonePrefix + phone.id, title: phone.name,
                      subtitle: [AddDeviceStrings.phoneRole, AddDeviceStrings.state(phone.connected ? "connected" : "offline")].joined(separator: " · "),
                      detail: nil, state: phone.connected ? "connected" : "offline", removable: true,
                      fullAccess: fullAccess, fullAccessHelp: fullAccess == nil ? nil : AddDeviceStrings.fullAccessHelp)
        }
        return rows
    }

    /// The activity lines with words a person reads: `(when, what, who)`.
    public var activityRows: [(time: String, what: String, subject: String)] {
        activity.map { ($0.ts, AddDeviceStrings.event($0.event ?? $0.decision ?? ""), $0.subject) }
    }

    /// Settings > Devices as the page reads it (`devices` in `cmux.settings.host.lists`), every
    /// text localized here.
    public func pageData(phones: [(id: String, name: String, connected: Bool)]) -> Data {
        let page = DevicesPage(
            title: AddDeviceStrings.devicesTitle, help: AddDeviceStrings.devicesHelp, empty: AddDeviceStrings.devicesEmpty,
            addTitle: AddDeviceStrings.addDeviceTitle, removeTitle: AddDeviceStrings.removeTitle,
            removeConfirmTitle: AddDeviceStrings.removeConfirmTitle, removeHelp: AddDeviceStrings.removeHelp,
            fullAccessTitle: AddDeviceStrings.fullAccessTitle, activityTitle: AddDeviceStrings.activityTitle, error: lastError,
            rows: rows(phones: phones).map {
                DevicesPage.Row(id: $0.id, title: $0.title, subtitle: $0.subtitle, detail: $0.detail, state: $0.state, removable: $0.removable,
                                fullAccess: $0.fullAccess, fullAccessHelp: $0.fullAccessHelp)
            },
            activity: activityRows.map { DevicesPage.Activity(time: $0.time, what: $0.what, subject: $0.subject) })
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(page)) ?? Data("null".utf8)
    }
}

/// The JSON shape of ``DeviceDirectory/pageData(phones:)``.
private nonisolated struct DevicesPage: Encodable {
    struct Row: Encodable {
        var id, title, subtitle: String
        var detail: String?
        var state: String
        var removable: Bool
        var fullAccess: Bool?
        var fullAccessHelp: String?
    }

    struct Activity: Encodable {
        var time, what, subject: String
    }

    var title, help, empty, addTitle, removeTitle, removeConfirmTitle, removeHelp, fullAccessTitle, activityTitle: String
    var error: String?
    var rows: [Row]
    var activity: [Activity]
}
