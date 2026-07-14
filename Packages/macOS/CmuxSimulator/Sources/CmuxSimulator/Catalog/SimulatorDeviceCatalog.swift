public import Foundation

/// The parsed device inventory from one `simctl list devices --json` run.
///
/// The catalog is a point-in-time value: it holds the devices as reported and
/// never re-queries CoreSimulator. Construct it from live `simctl` output (via
/// ``SimctlCommandRunning``) or from a fixture in tests:
///
/// ```swift
/// let data = try await runner.run(["list", "devices", "--json"])
/// let catalog = try SimulatorDeviceCatalog(simctlListJSON: data)
/// let device = catalog.device(matching: "iPhone 17 Pro")
/// ```
public struct SimulatorDeviceCatalog: Sendable {
    /// Every device in the catalog, in `simctl` order grouped by runtime.
    public let devices: [SimulatorDevice]

    /// Creates a catalog from already-parsed devices (used by tests and fakes).
    ///
    /// - Parameter devices: The devices the catalog should report.
    public init(devices: [SimulatorDevice]) {
        self.devices = devices
    }

    /// Parses the JSON produced by `xcrun simctl list devices --json`.
    ///
    /// Devices whose UDID is not a well-formed UUID are skipped rather than
    /// failing the whole catalog (they cannot be addressed safely anyway).
    ///
    /// - Parameter simctlListJSON: The raw stdout of the `simctl` invocation.
    /// - Throws: ``SimulatorCatalogError`` when the payload is not the
    ///   expected `{"devices": {runtime: [device]}}` shape.
    public init(simctlListJSON: Data) throws {
        let payload: SimctlListPayload
        do {
            payload = try JSONDecoder().decode(SimctlListPayload.self, from: simctlListJSON)
        } catch {
            throw SimulatorCatalogError(
                message: "simctl list output was not the expected JSON shape: \(error)"
            )
        }
        var devices: [SimulatorDevice] = []
        for (runtimeIdentifier, records) in payload.devices.sorted(by: { $0.key < $1.key }) {
            for record in records {
                guard let udid = SimulatorDeviceUDID(rawValue: record.udid) else { continue }
                devices.append(SimulatorDevice(
                    udid: udid,
                    name: record.name,
                    state: SimulatorDeviceState(simctlState: record.state),
                    isAvailable: record.isAvailable ?? false,
                    runtimeIdentifier: runtimeIdentifier,
                    deviceTypeIdentifier: record.deviceTypeIdentifier
                ))
            }
        }
        self.devices = devices
    }

    /// The device with the given UDID, if present.
    ///
    /// - Parameter udid: The identifier to look up.
    public func device(withUDID udid: SimulatorDeviceUDID) -> SimulatorDevice? {
        devices.first(where: { $0.udid == udid })
    }

    /// Resolves a user-supplied device query — a UDID or a device name.
    ///
    /// A well-formed UUID matches by UDID only. Otherwise the query matches
    /// device names case-insensitively; when several devices share the name,
    /// a booted one wins, then an available one, then `simctl` order.
    ///
    /// - Parameter query: The `--device` argument as typed by the user.
    /// - Returns: The best-matching device, or `nil` when nothing matches.
    public func device(matching query: String) -> SimulatorDevice? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let udid = SimulatorDeviceUDID(rawValue: trimmed) {
            return device(withUDID: udid)
        }
        let named = devices.filter { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        if let booted = named.first(where: { $0.state == .booted }) { return booted }
        if let available = named.first(where: { $0.isAvailable }) { return available }
        return named.first
    }

    /// Devices ordered for display: booted first, then available, then name.
    public var sortedForDisplay: [SimulatorDevice] {
        devices.sorted { lhs, rhs in
            let lhsBooted = lhs.state == .booted
            let rhsBooted = rhs.state == .booted
            if lhsBooted != rhsBooted { return lhsBooted }
            if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// The wire shape of `simctl list devices --json` (only the fields we read).
private struct SimctlListPayload: Decodable {
    let devices: [String: [SimctlDeviceRecord]]
}

/// One device record inside ``SimctlListPayload``.
private struct SimctlDeviceRecord: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool?
    let deviceTypeIdentifier: String?
}
