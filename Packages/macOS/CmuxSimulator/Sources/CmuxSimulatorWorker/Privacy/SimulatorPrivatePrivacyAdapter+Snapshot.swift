import CmuxSimulator
import Foundation

extension SimulatorPrivatePrivacyAdapter {
    func snapshot(
        deviceIdentifier: String,
        bundleIdentifier: String?
    ) async -> SimulatorPrivacySnapshot {
        let fallback = SimulatorPrivacySnapshot(
            deviceID: deviceIdentifier,
            bundleIdentifier: bundleIdentifier,
            authorizations: Self.emptyAuthorizations()
        )
        guard Self.isSafeIdentifier(deviceIdentifier),
              bundleIdentifier.map(Self.isSafeIdentifier) ?? true
        else { return fallback }
        do {
            return try await mutationGate.withLocks([
                .tcc(deviceIdentifier: deviceIdentifier),
                .store(deviceIdentifier: deviceIdentifier, name: "BulletinBoard"),
            ]) {
                await snapshotWhileLocked(
                    deviceIdentifier: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier
                )
            }
        } catch {
            return fallback
        }
    }

    private func snapshotWhileLocked(
        deviceIdentifier: String,
        bundleIdentifier: String?
    ) async -> SimulatorPrivacySnapshot {
        var authorizations = Self.emptyAuthorizations()
        let databaseURL = simulatorLibrary(deviceIdentifier: deviceIdentifier)
            .appendingPathComponent("TCC/TCC.db")
        let locationEntries = Self.locationEntries(deviceIdentifier: deviceIdentifier)
        let notificationSections = Self.notificationSections(deviceIdentifier: deviceIdentifier)

        if let bundleIdentifier {
            if FileManager.default.isReadableFile(atPath: databaseURL.path),
               let rows = try? await readTCCRows(
                   databaseURL: databaseURL,
                   bundleIdentifier: bundleIdentifier
               ) {
                Self.applyTCCRows(rows, to: &authorizations)
            }
            Self.applyLocation(
                bundleIdentifier: bundleIdentifier,
                entries: locationEntries,
                to: &authorizations
            )
            Self.applyNotifications(
                bundleIdentifier: bundleIdentifier,
                sections: notificationSections,
                to: &authorizations
            )
            return SimulatorPrivacySnapshot(
                deviceID: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                authorizations: authorizations
            )
        }

        let tccReadback: SimulatorTCCApplicationReadback? = if FileManager.default
            .isReadableFile(atPath: databaseURL.path) {
            try? await readTCCApplicationRows(databaseURL: databaseURL)
        } else { nil }
        let tccRows = Dictionary(
            uniqueKeysWithValues: (tccReadback?.applications ?? []).map {
                ($0.bundleIdentifier, $0.services)
            }
        )
        var bundleIdentifiers = Set(tccRows.keys)
        bundleIdentifiers.formUnion(Self.locationBundleIdentifiers(in: locationEntries))
        bundleIdentifiers.formUnion(Self.notificationBundleIdentifiers(in: notificationSections))
        let sortedBundleIdentifiers = bundleIdentifiers.sorted()
        let applications = sortedBundleIdentifiers
            .prefix(Self.maximumUnfilteredApplications)
            .map { bundleIdentifier in
                var values = Self.emptyAuthorizations()
                Self.applyTCCRows(tccRows[bundleIdentifier] ?? [:], to: &values)
                Self.applyLocation(
                    bundleIdentifier: bundleIdentifier,
                    entries: locationEntries,
                    to: &values
                )
                Self.applyNotifications(
                    bundleIdentifier: bundleIdentifier,
                    sections: notificationSections,
                    to: &values
                )
                return SimulatorPrivacyApplicationSnapshot(
                    bundleIdentifier: bundleIdentifier,
                    authorizations: values
                )
            }
        return SimulatorPrivacySnapshot(
            deviceID: deviceIdentifier,
            bundleIdentifier: nil,
            authorizations: authorizations,
            applications: applications,
            isTruncated: tccReadback?.isTruncated == true
                || sortedBundleIdentifiers.count > Self.maximumUnfilteredApplications
        )
    }

    private static func emptyAuthorizations()
        -> [SimulatorPrivacyService: SimulatorPrivacyAuthorization] {
        Dictionary(
            uniqueKeysWithValues: SimulatorPrivacyService.allCases
                .filter { $0 != .all }
                .map { ($0, SimulatorPrivacyAuthorization.unknown) }
        )
    }

    private static func locationEntries(deviceIdentifier: String) -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            .appendingPathComponent(deviceIdentifier)
            .appendingPathComponent("data/Library/Caches/locationd/clients.plist")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private static func locationBundleIdentifiers(in entries: [String: Any]?) -> Set<String> {
        guard let entries else { return [] }
        return Set(entries.keys.compactMap { key in
            guard key.hasPrefix("i"), key.hasSuffix(":"), key.count > 2 else { return nil }
            let bundleIdentifier = String(key.dropFirst().dropLast())
            return isSafeIdentifier(bundleIdentifier) ? bundleIdentifier : nil
        })
    }

    private static func applyLocation(
        bundleIdentifier: String,
        entries: [String: Any]?,
        to authorizations: inout [SimulatorPrivacyService: SimulatorPrivacyAuthorization]
    ) {
        guard let entry = entries?["i\(bundleIdentifier):"] as? [String: Any],
              let raw = entry["Authorization"] as? NSNumber
        else {
            authorizations[.location] = .notDetermined
            authorizations[.locationAlways] = .notDetermined
            authorizations[.locationInUse] = .notDetermined
            return
        }
        let value: SimulatorPrivacyAuthorization = switch raw.intValue {
        case 0: .notDetermined
        case 1, 2: .denied
        case 3, 4: .granted
        default: .unknown
        }
        authorizations[.location] = value
        authorizations[.locationAlways] = raw.intValue == 3 ? .granted : value
        authorizations[.locationInUse] = raw.intValue == 4 ? .granted : value
    }

    private static func notificationSections(deviceIdentifier: String) -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            .appendingPathComponent(deviceIdentifier)
            .appendingPathComponent("data/Library/BulletinBoard/VersionedSectionInfo.plist")
        guard let data = try? Data(contentsOf: path),
              let root = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return nil }
        return root["sectionInfo"] as? [String: Any]
    }

    private static func notificationBundleIdentifiers(in sections: [String: Any]?) -> Set<String> {
        guard let sections else { return [] }
        return Set(sections.keys.filter(isSafeIdentifier))
    }

    private static func applyNotifications(
        bundleIdentifier: String,
        sections: [String: Any]?,
        to authorizations: inout [SimulatorPrivacyService: SimulatorPrivacyAuthorization]
    ) {
        guard let archiveData = sections?[bundleIdentifier] as? Data
        else {
            authorizations[.notifications] = .notDetermined
            authorizations[.criticalNotifications] = .notDetermined
            return
        }
        guard let archive = try? PropertyListSerialization.propertyList(
            from: archiveData,
            options: [],
            format: nil
        ) as? [String: Any],
              let objects = archive["$objects"] as? [Any],
              objects.indices.contains(3),
              let settings = objects[3] as? [String: Any]
        else {
            authorizations[.notifications] = .unknown
            authorizations[.criticalNotifications] = .unknown
            return
        }
        let allowed = (settings["allowsNotifications"] as? NSNumber)?.boolValue
        let critical = (settings["criticalAlertSetting"] as? NSNumber)?.intValue == 2
        authorizations[.notifications] = allowed.map { $0 ? .granted : .denied } ?? .unknown
        authorizations[.criticalNotifications] = if allowed == true, critical {
            .critical
        } else if allowed == false {
            .denied
        } else {
            .notDetermined
        }
    }
}
