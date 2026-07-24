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
            authorizations: emptyAuthorizations()
        )
        guard simulatorPrivacyIdentifierIsSafe(deviceIdentifier),
              bundleIdentifier.map(simulatorPrivacyIdentifierIsSafe) ?? true
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
        var authorizations = emptyAuthorizations()
        let databaseURL = simulatorLibrary(deviceIdentifier: deviceIdentifier)
            .appendingPathComponent("TCC/TCC.db")
        let locationEntries = locationEntries(deviceIdentifier: deviceIdentifier)
        let notificationSections = notificationSections(deviceIdentifier: deviceIdentifier)

        if let bundleIdentifier {
            if fileSystem.isReadableFile(atPath: databaseURL.path),
               let rows = try? await readTCCRows(
                   databaseURL: databaseURL,
                   bundleIdentifier: bundleIdentifier
               ) {
                applyTCCRows(rows, to: &authorizations)
            }
            applyLocation(
                bundleIdentifier: bundleIdentifier,
                entries: locationEntries,
                to: &authorizations
            )
            applyNotifications(
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

        let tccReadback: SimulatorTCCApplicationReadback? = if fileSystem
            .isReadableFile(atPath: databaseURL.path) {
            try? await readTCCApplicationRows(databaseURL: databaseURL)
        } else { nil }
        let tccRows = Dictionary(
            uniqueKeysWithValues: (tccReadback?.applications ?? []).map {
                ($0.bundleIdentifier, $0.services)
            }
        )
        var bundleIdentifiers = Set(tccRows.keys)
        bundleIdentifiers.formUnion(locationBundleIdentifiers(in: locationEntries))
        bundleIdentifiers.formUnion(notificationBundleIdentifiers(in: notificationSections))
        let sortedBundleIdentifiers = bundleIdentifiers.sorted()
        let applications = sortedBundleIdentifiers
            .prefix(Self.maximumUnfilteredApplications)
            .map { bundleIdentifier in
                var values = emptyAuthorizations()
                applyTCCRows(tccRows[bundleIdentifier] ?? [:], to: &values)
                applyLocation(
                    bundleIdentifier: bundleIdentifier,
                    entries: locationEntries,
                    to: &values
                )
                applyNotifications(
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

    private func emptyAuthorizations()
        -> [SimulatorPrivacyService: SimulatorPrivacyAuthorization] {
        Dictionary(
            uniqueKeysWithValues: SimulatorPrivacyService.allCases
                .filter { $0 != .all }
                .map { ($0, SimulatorPrivacyAuthorization.unknown) }
        )
    }

    private func locationEntries(deviceIdentifier: String) -> [String: Any]? {
        let path = simulatorDevicesDirectory
            .appendingPathComponent(deviceIdentifier)
            .appendingPathComponent("data/Library/Caches/locationd/clients.plist")
        guard let data = fileSystem.contents(atPath: path.path) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private func locationBundleIdentifiers(in entries: [String: Any]?) -> Set<String> {
        guard let entries else { return [] }
        return Set(entries.keys.compactMap { key in
            guard key.hasPrefix("i"), key.hasSuffix(":"), key.count > 2 else { return nil }
            let bundleIdentifier = String(key.dropFirst().dropLast())
            return simulatorPrivacyIdentifierIsSafe(bundleIdentifier) ? bundleIdentifier : nil
        })
    }

    private func applyLocation(
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

    private func notificationSections(deviceIdentifier: String) -> [String: Any]? {
        let path = simulatorDevicesDirectory
            .appendingPathComponent(deviceIdentifier)
            .appendingPathComponent("data/Library/BulletinBoard/VersionedSectionInfo.plist")
        guard let data = fileSystem.contents(atPath: path.path),
              let root = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return nil }
        return root["sectionInfo"] as? [String: Any]
    }

    private func notificationBundleIdentifiers(in sections: [String: Any]?) -> Set<String> {
        guard let sections else { return [] }
        return Set(sections.keys.filter(simulatorPrivacyIdentifierIsSafe))
    }

    private func applyNotifications(
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
