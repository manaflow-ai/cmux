import CmuxSimulator
import Foundation

/// Isolated mutations for serve-sim permission values that public `simctl`
/// does not expose. TCC row semantics and the BulletinBoard archive template
/// are adapted from serve-sim (Apache-2.0, Evan Bacon).
struct SimulatorPrivatePrivacyAdapter: Sendable {
    let subprocessRunner: SimulatorSubprocessRunner
    let sqliteBusyTimeoutMilliseconds: Int

    init(
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner(),
        sqliteBusyTimeoutMilliseconds: Int = 5_000
    ) {
        self.subprocessRunner = subprocessRunner
        self.sqliteBusyTimeoutMilliseconds = max(0, sqliteBusyTimeoutMilliseconds)
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3")
            && FileManager.default.isExecutableFile(atPath: "/usr/libexec/PlistBuddy")
    }

    func set(
        deviceIdentifier: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String
    ) async throws {
        guard Self.isSafeIdentifier(deviceIdentifier), Self.isSafeIdentifier(bundleIdentifier) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Permission mutation rejected an invalid device or bundle identifier."
            )
        }
        if service == .all {
            guard action == .reset else {
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "The private permission adapter only supports reset for the all service."
                )
            }
            for value in [
                SimulatorPrivacyService.camera,
                SimulatorPrivacyService.photosLimited,
                .notifications,
                .speech,
                .faceID,
                .userTracking,
                .homeKit,
            ] {
                try await set(
                    deviceIdentifier: deviceIdentifier,
                    action: .reset,
                    service: value,
                    bundleIdentifier: bundleIdentifier
                )
            }
            return
        }

        switch service {
        case .notifications, .criticalNotifications:
            try await setNotifications(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                action: action,
                critical: service == .criticalNotifications
            )
        case .camera, .photosLimited, .speech, .faceID, .userTracking, .homeKit:
            try await setTCC(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                action: action,
                service: service
            )
        default:
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "\(service.rawValue) belongs to public simctl privacy, not the isolated adapter."
            )
        }
    }

    func snapshot(
        deviceIdentifier: String,
        bundleIdentifier: String?
    ) async -> SimulatorPrivacySnapshot {
        var authorizations = Self.emptyAuthorizations()
        guard Self.isSafeIdentifier(deviceIdentifier),
              bundleIdentifier.map(Self.isSafeIdentifier) ?? true
        else {
            return SimulatorPrivacySnapshot(
                deviceID: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                authorizations: authorizations
            )
        }

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
        let selectedBundleIdentifiers = sortedBundleIdentifiers.prefix(
            Self.maximumUnfilteredApplications
        )
        let applications = selectedBundleIdentifiers.map { bundleIdentifier in
            var applicationAuthorizations = Self.emptyAuthorizations()
            Self.applyTCCRows(
                tccRows[bundleIdentifier] ?? [:],
                to: &applicationAuthorizations
            )
            Self.applyLocation(
                bundleIdentifier: bundleIdentifier,
                entries: locationEntries,
                to: &applicationAuthorizations
            )
            Self.applyNotifications(
                bundleIdentifier: bundleIdentifier,
                sections: notificationSections,
                to: &applicationAuthorizations
            )
            return SimulatorPrivacyApplicationSnapshot(
                bundleIdentifier: bundleIdentifier,
                authorizations: applicationAuthorizations
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

    private func setNotifications(
        deviceIdentifier: String,
        bundleIdentifier: String,
        action: SimulatorPrivacyAction,
        critical: Bool
    ) async throws {
        let destination = simulatorLibrary(deviceIdentifier: deviceIdentifier)
            .appendingPathComponent("BulletinBoard/VersionedSectionInfo.plist")
        guard FileManager.default.fileExists(atPath: destination.path) else {
            if action == .reset { return }
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The Simulator BulletinBoard store is unavailable; wait for SpringBoard to finish booting."
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-simulator-permission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let blob = temporaryDirectory.appendingPathComponent("section-info.plist")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        _ = try? await run(
            executable: "/usr/bin/chflags",
            arguments: ["nouchg", destination.path]
        )
        do {
            _ = try? await plistBuddy(
                commands: ["Delete :sectionInfo:\(bundleIdentifier)", "Save"],
                file: destination,
                allowsFailure: true
            )
            if action != .reset {
                guard let data = Data(base64Encoded: Self.notificationTemplateBase64) else {
                    throw SimulatorWorkerFailure.privateAPIUnavailable(
                        "The bundled notification permission template is invalid."
                    )
                }
                try data.write(to: blob, options: .atomic)
                let enabled = action == .grant
                try await plistBuddy(
                    commands: [
                        "Set :$objects:2 \(bundleIdentifier)",
                        "Set :$objects:3:allowsNotifications \(enabled ? "true" : "false")",
                        "Add :$objects:3:criticalAlertSetting integer " +
                            "\(enabled && critical ? 2 : 0)",
                        "Set :$objects:5 \(bundleIdentifier)",
                        "Save",
                    ],
                    file: blob
                )
                try await runExpectingSuccess(
                    executable: "/usr/bin/plutil",
                    arguments: ["-convert", "binary1", blob.path]
                )
                try await plistBuddy(
                    commands: ["Import :sectionInfo:\(bundleIdentifier) \(blob.path)", "Save"],
                    file: destination
                )
            }
            try await runExpectingSuccess(
                executable: "/usr/bin/plutil",
                arguments: ["-convert", "binary1", destination.path]
            )
        } catch {
            await restoreBulletinBoardFlags(destination)
            throw error
        }
        await restoreBulletinBoardFlags(destination)
    }

    private func restoreBulletinBoardFlags(_ url: URL) async {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
        _ = try? await run(
            executable: "/usr/bin/chflags",
            arguments: ["uchg", url.path]
        )
    }

    @discardableResult
    private func plistBuddy(
        commands: [String],
        file: URL,
        allowsFailure: Bool = false
    ) async throws -> SimulatorSubprocessResult {
        var arguments: [String] = []
        for command in commands {
            arguments += ["-c", command]
        }
        arguments.append(file.path)
        let result = try await run(
            executable: "/usr/libexec/PlistBuddy",
            arguments: arguments
        )
        if !allowsFailure, result.status != 0 {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                detail.isEmpty ? "The Simulator BulletinBoard update failed." : detail
            )
        }
        return result
    }

    private func runExpectingSuccess(executable: String, arguments: [String]) async throws {
        let result = try await run(executable: executable, arguments: arguments)
        guard result.status == 0 else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                detail.isEmpty ? "The permission store command failed." : detail
            )
        }
    }

    private func run(
        executable: String,
        arguments: [String]
    ) async throws -> SimulatorSubprocessResult {
        try await subprocessRunner.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments
        )
    }

    func simulatorLibrary(deviceIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            .appendingPathComponent(deviceIdentifier)
            .appendingPathComponent("data/Library")
    }

    private static func locationEntries(
        deviceIdentifier: String
    ) -> [String: Any]? {
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

    private static func locationBundleIdentifiers(
        in entries: [String: Any]?
    ) -> Set<String> {
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

    private static func notificationSections(
        deviceIdentifier: String
    ) -> [String: Any]? {
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

    private static func notificationBundleIdentifiers(
        in sections: [String: Any]?
    ) -> Set<String> {
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

    static func isSafeIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 255, asciiAlphaNumeric(bytes[0]) else {
            return false
        }
        return bytes.allSatisfy { asciiAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E }
    }

    private static func asciiAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }

    private static let notificationTemplateBase64 =
        "YnBsaXN0MDDUAQIDBAUGTU5YJHZlcnNpb25YJG9iamVjdHNZJGFyY2hpdmVyVCR0b3ASAAGGoKgHCDAxQUgfSVUkbnVsbN8QFQkKCwwNDg8QERITFBUWFxgZGhscHR4fHiEiIx4jJicfHygjIh8jIyMjI18QFHN1cHByZXNzRnJvbVNldHRpbmdzXxASc3VwcHJlc3NlZFNldHRpbmdzWmhpZGVXZWVBcHBZc2VjdGlvbklEW2Rpc3BsYXlOYW1lVGljb25fEBlkaXNwbGF5c0NyaXRpY2FsQnVsbGV0aW5zW3N1YnNlY3Rpb25zXxATc2VjdGlvbkluZm9TZXR0aW5nc1YkY2xhc3NfEA9zZWN0aW9uQ2F0ZWdvcnlfEBJzdWJzZWN0aW9uUHJpb3JpdHlXdmVyc2lvbl8QGm1hbmFnZWRTZWN0aW9uSW5mb1NldHRpbmdzV2FwcE5hbWVbc2VjdGlvblR5cGVfEBBmYWN0b3J5U2VjdGlvbklEXxAPZGF0YVByb3ZpZGVySURzXHN1YnNlY3Rpb25JRFdmaWx0ZXJzXxAYcGF0aFRvV2VlQXBwUGx1Z2luQnVuZGxlCBAACIACgAWAAAiAAIADgAeABoAAgAWAAIAAgACAAIAAXxAmY29tLkxlb05hdGFuLkxOUG9wdXBDb250cm9sbGVyRXhhbXBsZS3ZMjM0NTY3Ejg5Ojs7Ox8fPjtAXHB1c2hTZXR0aW5nc18QGXNob3dzSW5Ob3RpZmljYXRpb25DZW50ZXJfEBNhbGxvd3NOb3RpZmljYXRpb25zXxAWc2hvd3NPbkV4dGVybmFsRGV2aWNlc18QFWNvbnRlbnRQcmV2aWV3U2V0dGluZ15jYXJQbGF5U2V0dGluZ18QEXNob3dzSW5Mb2NrU2NyZWVuWWFsZXJ0VHlwZRA/CQkJgAQJEAHSQkNERVokY2xhc3NuYW1lWCRjbGFzc2VzXxAVQkJTZWN0aW9uSW5mb1NldHRpbmdzokZHXxAVQkJTZWN0aW9uSW5mb1NldHRpbmdzWE5TT2JqZWN0V0xOUG9wdXDSQkNKS11CQlNlY3Rpb25JbmZvokxHXUJCU2VjdGlvbkluZm9fEA9OU0tleWVkQXJjaGl2ZXLRT1BUcm9vdIABAAgAEQAaACMALQAyADcAQABGAHMAigCfAKoAtADAAMUA4QDtAQMBCgEcATEBOQFWAV4BagF9AY8BnAGkAb8BwAHCAcMBxQHHAckBygHMAc4B0AHSAdQB1gHYAdoB3AHeAeACCQIcAikCRQJbAnQCjAKbAq8CuQK7ArwCvQK+AsACwQLDAsgC0wLcAvQC9wMPAxgDIAMlAzMDNgNEA1YDWQNeAAAAAAAAAgEAAAAAAAAAUQAAAAAAAAAAAAAAAAAAA2A="
}
