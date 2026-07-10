import Foundation

extension SimulatorControlService {
    public func discoverDevices() async throws -> [SimulatorDevice] {
        let deviceData = try await output(arguments: ["simctl", "list", "devices", "--json"])
        let runtimeData = try await output(arguments: ["simctl", "list", "runtimes", "--json"])

        let decoder = JSONDecoder()
        let deviceList: DeviceListResponse
        let runtimeList: RuntimeListResponse
        do {
            deviceList = try decoder.decode(DeviceListResponse.self, from: deviceData)
            runtimeList = try decoder.decode(RuntimeListResponse.self, from: runtimeData)
        } catch {
            throw SimulatorControlError(
                code: "invalid_simctl_json",
                arguments: ["simctl", "list"],
                message: "Xcode returned an unreadable Simulator device list: \(error)"
            )
        }

        var preferredRuntimes: [String: RuntimeRecord] = [:]
        for runtime in runtimeList.runtimes {
            if let existing = preferredRuntimes[runtime.identifier],
               !Self.prefers(runtime, over: existing) {
                continue
            }
            preferredRuntimes[runtime.identifier] = runtime
        }
        let runtimeNames = preferredRuntimes.mapValues(\.name)
        var productFamilies: [String: String] = [:]
        for runtime in runtimeList.runtimes {
            for deviceType in runtime.supportedDeviceTypes ?? [] {
                productFamilies[deviceType.identifier] = deviceType.productFamily
            }
        }

        return deviceList.devices.flatMap { runtimeIdentifier, records in
            records.map { record in
                SimulatorDevice(
                    id: record.udid,
                    name: record.name,
                    runtimeIdentifier: runtimeIdentifier,
                    runtimeName: runtimeNames[runtimeIdentifier] ?? Self.runtimeName(from: runtimeIdentifier),
                    deviceTypeIdentifier: record.deviceTypeIdentifier,
                    family: Self.family(
                        productFamily: productFamilies[record.deviceTypeIdentifier],
                        name: record.name,
                        deviceTypeIdentifier: record.deviceTypeIdentifier
                    ),
                    state: SimulatorDeviceState(simctlState: record.state),
                    isAvailable: record.isAvailable ?? true,
                    lastBootedAt: record.lastBootedAt.flatMap(Self.parseDate)
                )
            }
        }
    }

    /// Boots a device, treating an already booted device as success.
    public func boot(deviceID: String) async throws {
        let arguments = ["simctl", "boot", deviceID]
        let result = await run(arguments: arguments)
        if Self.succeeded(result) || Self.diagnostic(for: result).localizedCaseInsensitiveContains("current state: Booted") {
            return
        }
        throw Self.failure(result: result, arguments: arguments)
    }

    /// Waits for device boot and data migration to finish.
    public func waitUntilBooted(deviceID: String) async throws {
        _ = try await output(
            arguments: ["simctl", "bootstatus", deviceID, "-b"],
            timeout: bootTimeout
        )
    }

    /// Shuts down a device, treating an already stopped device as success.
    public func shutdown(deviceID: String) async throws {
        let arguments = ["simctl", "shutdown", deviceID]
        let result = await run(arguments: arguments)
        if Self.succeeded(result) || Self.diagnostic(for: result).localizedCaseInsensitiveContains("current state: Shutdown") {
            return
        }
        throw Self.failure(result: result, arguments: arguments)
    }

    /// Lists installed user and system applications.

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func runtimeName(from identifier: String) -> String {
        let marker = ".SimRuntime."
        let suffix = identifier.components(separatedBy: marker).last ?? identifier
        let pieces = suffix.split(separator: "-")
        guard pieces.count >= 2 else { return suffix }
        return "\(pieces[0]) \(pieces.dropFirst().joined(separator: "."))"
    }

    static func family(
        productFamily: String?,
        name: String,
        deviceTypeIdentifier: String
    ) -> SimulatorDeviceFamily {
        let value = (productFamily ?? "\(name) \(deviceTypeIdentifier)").lowercased()
        if value.contains("iphone") { return .iPhone }
        if value.contains("ipad") { return .iPad }
        if value.contains("watch") { return .watch }
        if value.contains("vision") { return .vision }
        if value.contains("tv") { return .television }
        return .unknown
    }

    static func prefers(_ candidate: RuntimeRecord, over existing: RuntimeRecord) -> Bool {
        let candidateAvailable = candidate.isAvailable ?? true
        let existingAvailable = existing.isAvailable ?? true
        if candidateAvailable != existingAvailable {
            return candidateAvailable
        }
        let candidateVersion = candidate.version ?? candidate.name
        let existingVersion = existing.version ?? existing.name
        return candidateVersion.compare(existingVersion, options: .numeric) == .orderedDescending
    }


struct DeviceListResponse: Decodable {
    let devices: [String: [DeviceRecord]]
}

struct DeviceRecord: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool?
    let deviceTypeIdentifier: String
    let lastBootedAt: String?
}

struct RuntimeListResponse: Decodable {
    let runtimes: [RuntimeRecord]
}

struct RuntimeRecord: Decodable {
    let identifier: String
    let name: String
    let version: String?
    let isAvailable: Bool?
    let supportedDeviceTypes: [RuntimeDeviceType]?
}

struct RuntimeDeviceType: Decodable {
    let identifier: String
    let productFamily: String
}
}
