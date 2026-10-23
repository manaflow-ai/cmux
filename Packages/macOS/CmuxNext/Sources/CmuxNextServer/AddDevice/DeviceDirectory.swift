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
    /// Why the last remove failed, as the CLI said it; nil after a success.
    public private(set) var lastError: String?

    /// Runs `cmux-tui <arguments>` and returns its stdout, nil when it failed.
    @ObservationIgnored private let run: ([String]) async -> Data?
    /// Forgets a phone paired with this Mac (`IPhoneHostService.revokePhone`).
    @ObservationIgnored private let removePhone: (String) async -> Void
    @ObservationIgnored private var reading = false

    /// - Parameters:
    ///   - run: The app's own `cmux-tui` run (tests pass fixture JSON).
    ///   - removePhone: The Mac's phone pairing's remove.
    public init(run: @escaping ([String]) async -> Data?, removePhone: @escaping (String) async -> Void) {
        self.run = run
        self.removePhone = removePhone
    }

    /// The id prefix of a phone row (its pairing lives in the Mac app, not in the CLI's stores).
    public static let phonePrefix = "phone:"

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
        let ok = await run(["device", "remove", id, "--yes", "--json"]) != nil
        lastError = ok ? nil : AddDeviceStrings.removeFailed
        await refresh()
        return lastError
    }

    /// The rows Settings shows: the CLI's devices, then `phones` (the Mac's paired phones as
    /// `(id, name, connected)`), with words a person reads.
    public func rows(phones: [(id: String, name: String, connected: Bool)]) -> [DeviceListRow] {
        var rows = (listing?.devices ?? []).map { device in
            let roles = device.roles.map(AddDeviceStrings.role).joined(separator: ", ")
            return DeviceListRow(id: device.id, title: device.name, subtitle: [roles, AddDeviceStrings.state(device.state)].filter { !$0.isEmpty }.joined(separator: " · "),
                             detail: device.detail, state: device.state, removable: true)
        }
        rows += phones.map { phone in
            DeviceListRow(id: Self.phonePrefix + phone.id, title: phone.name,
                      subtitle: [AddDeviceStrings.phoneRole, AddDeviceStrings.state(phone.connected ? "connected" : "offline")].joined(separator: " · "),
                      detail: nil, state: phone.connected ? "connected" : "offline", removable: true)
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
            activityTitle: AddDeviceStrings.activityTitle, error: lastError,
            rows: rows(phones: phones).map { DevicesPage.Row(id: $0.id, title: $0.title, subtitle: $0.subtitle, detail: $0.detail, state: $0.state, removable: $0.removable) },
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
    }

    struct Activity: Encodable {
        var time, what, subject: String
    }

    var title, help, empty, addTitle, removeTitle, removeConfirmTitle, removeHelp, activityTitle: String
    var error: String?
    var rows: [Row]
    var activity: [Activity]
}
