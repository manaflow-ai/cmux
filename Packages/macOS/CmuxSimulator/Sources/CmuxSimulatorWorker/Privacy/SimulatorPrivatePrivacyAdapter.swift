import CmuxSimulator
import Foundation

/// Isolated mutations for serve-sim permission values that public `simctl`
/// does not expose. TCC row semantics and the BulletinBoard archive template
/// are adapted from serve-sim (Apache-2.0, Evan Bacon).
struct SimulatorPrivatePrivacyAdapter: Sendable {
    let subprocessRunner: SimulatorSubprocessRunner
    let sqliteBusyTimeoutMilliseconds: Int
    let mutationGate: SimulatorMutationGate
    let fileSystem: SimulatorPrivacyFileSystem
    let simulatorDevicesDirectory: URL

    init(
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner(),
        sqliteBusyTimeoutMilliseconds: Int = 5_000,
        mutationGate: SimulatorMutationGate = SimulatorMutationGate(),
        fileSystem: SimulatorPrivacyFileSystem = SimulatorPrivacyFileSystem(),
        simulatorDevicesDirectory: URL? = nil
    ) {
        self.subprocessRunner = subprocessRunner
        self.sqliteBusyTimeoutMilliseconds = max(0, sqliteBusyTimeoutMilliseconds)
        self.mutationGate = mutationGate
        self.fileSystem = fileSystem
        let userLibrary = fileSystem.userLibraryDirectory()
            ?? URL(fileURLWithPath: "/Library", isDirectory: true)
        self.simulatorDevicesDirectory = simulatorDevicesDirectory
            ?? userLibrary.appendingPathComponent("Developer/CoreSimulator/Devices")
    }

    var isAvailable: Bool {
        fileSystem.isExecutableFile(atPath: "/usr/bin/sqlite3")
            && fileSystem.isExecutableFile(atPath: "/usr/libexec/PlistBuddy")
    }

    func set(
        deviceIdentifier: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String
    ) async throws {
        guard simulatorPrivacyIdentifierIsSafe(deviceIdentifier),
              simulatorPrivacyIdentifierIsSafe(bundleIdentifier) else {
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
            try await mutationGate.withLocks([
                .tcc(deviceIdentifier: deviceIdentifier),
                .store(deviceIdentifier: deviceIdentifier, name: "BulletinBoard"),
            ]) {
                for value in [
                    SimulatorPrivacyService.camera,
                    .photosLimited,
                    .speech,
                    .faceID,
                    .userTracking,
                    .homeKit,
                ] {
                    try await setTCC(
                        deviceIdentifier: deviceIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        action: .reset,
                        service: value
                    )
                }
                try await mutateNotifications(
                    deviceIdentifier: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    action: .reset,
                    critical: false,
                    blob: nil
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
            try await mutationGate.withLocks([.tcc(deviceIdentifier: deviceIdentifier)]) {
                try await setTCC(
                    deviceIdentifier: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    action: action,
                    service: service
                )
            }
        default:
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "\(service.rawValue) belongs to public simctl privacy, not the isolated adapter."
            )
        }
    }

    private func setNotifications(
        deviceIdentifier: String,
        bundleIdentifier: String,
        action: SimulatorPrivacyAction,
        critical: Bool
    ) async throws {
        let prepared = try await prepareNotificationBlob(
            bundleIdentifier: bundleIdentifier,
            action: action,
            critical: critical
        )
        defer {
            if let temporaryDirectory = prepared?.temporaryDirectory {
                try? fileSystem.removeItem(at: temporaryDirectory)
            }
        }
        try await mutationGate.withLocks([
            .store(deviceIdentifier: deviceIdentifier, name: "BulletinBoard"),
        ]) {
            try await mutateNotifications(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                action: action,
                critical: critical,
                blob: prepared?.blob
            )
        }
    }

    func mutateNotifications(
        deviceIdentifier: String,
        bundleIdentifier: String,
        action: SimulatorPrivacyAction,
        critical: Bool,
        blob: URL?
    ) async throws {
        let destination = simulatorLibrary(deviceIdentifier: deviceIdentifier)
            .appendingPathComponent("BulletinBoard/VersionedSectionInfo.plist")
        guard fileSystem.fileExists(atPath: destination.path) else {
            if action == .reset { return }
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The Simulator BulletinBoard store is unavailable; wait for SpringBoard to finish booting."
            )
        }

        guard let original = fileSystem.contents(atPath: destination.path) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The Simulator BulletinBoard store could not be staged."
            )
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".cmux-\(UUID().uuidString)-VersionedSectionInfo.plist"
        )
        try original.write(to: staged, options: [.atomic])
        defer { try? fileSystem.removeItem(at: staged) }

        var destinationFlagsCleared = false
        do {
            _ = try? await plistBuddy(
                commands: ["Delete :sectionInfo:\(bundleIdentifier)", "Save"],
                file: staged,
                allowsFailure: true
            )
            if action != .reset {
                guard let blob else {
                    throw SimulatorWorkerFailure.privateAPIUnavailable(
                        "The prepared notification permission template is unavailable."
                    )
                }
                try await plistBuddy(
                    commands: ["Import :sectionInfo:\(bundleIdentifier) \(blob.path)", "Save"],
                    file: staged
                )
            }
            try await runExpectingSuccess(
                executable: "/usr/bin/plutil",
                arguments: ["-convert", "binary1", staged.path]
            )
            _ = try? await run(
                executable: "/usr/bin/chflags",
                arguments: ["nouchg", destination.path]
            )
            destinationFlagsCleared = true
            try fileSystem.replaceItem(at: destination, with: staged)
        } catch {
            if destinationFlagsCleared {
                await restoreBulletinBoardFlags(destination)
            }
            throw error
        }
        await restoreBulletinBoardFlags(destination)
    }

    private func prepareNotificationBlob(
        bundleIdentifier: String,
        action: SimulatorPrivacyAction,
        critical: Bool
    ) async throws -> (temporaryDirectory: URL, blob: URL)? {
        guard action != .reset else { return nil }
        guard let data = Data(base64Encoded: Self.notificationTemplateBase64) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The bundled notification permission template is invalid."
            )
        }
        let temporaryDirectory = fileSystem.temporaryDirectory
            .appendingPathComponent("cmux-simulator-permission-\(UUID().uuidString)")
        try fileSystem.createDirectory(
            at: temporaryDirectory,
            attributes: [.posixPermissions: 0o700]
        )
        let blob = temporaryDirectory.appendingPathComponent("section-info.plist")
        do {
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
        } catch {
            try? fileSystem.removeItem(at: temporaryDirectory)
            throw error
        }
        return (temporaryDirectory, blob)
    }

    private func restoreBulletinBoardFlags(_ url: URL) async {
        try? fileSystem.setAttributes(
            [.posixPermissions: 0o644],
            atPath: url.path
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
        simulatorDevicesDirectory.appendingPathComponent(deviceIdentifier)
            .appendingPathComponent("data/Library")
    }

    private static let notificationTemplateBase64 =
        "YnBsaXN0MDDUAQIDBAUGTU5YJHZlcnNpb25YJG9iamVjdHNZJGFyY2hpdmVyVCR0b3ASAAGGoKgHCDAxQUgfSVUkbnVsbN8QFQkKCwwNDg8QERITFBUWFxgZGhscHR4fHiEiIx4jJicfHygjIh8jIyMjI18QFHN1cHByZXNzRnJvbVNldHRpbmdzXxASc3VwcHJlc3NlZFNldHRpbmdzWmhpZGVXZWVBcHBZc2VjdGlvbklEW2Rpc3BsYXlOYW1lVGljb25fEBlkaXNwbGF5c0NyaXRpY2FsQnVsbGV0aW5zW3N1YnNlY3Rpb25zXxATc2VjdGlvbkluZm9TZXR0aW5nc1YkY2xhc3NfEA9zZWN0aW9uQ2F0ZWdvcnlfEBJzdWJzZWN0aW9uUHJpb3JpdHlXdmVyc2lvbl8QGm1hbmFnZWRTZWN0aW9uSW5mb1NldHRpbmdzV2FwcE5hbWVbc2VjdGlvblR5cGVfEBBmYWN0b3J5U2VjdGlvbklEXxAPZGF0YVByb3ZpZGVySURzXHN1YnNlY3Rpb25JRFdmaWx0ZXJzXxAYcGF0aFRvV2VlQXBwUGx1Z2luQnVuZGxlCBAACIACgAWAAAiAAIADgAeABoAAgAWAAIAAgACAAIAAXxAmY29tLkxlb05hdGFuLkxOUG9wdXBDb250cm9sbGVyRXhhbXBsZS3ZMjM0NTY3Ejg5Ojs7Ox8fPjtAXHB1c2hTZXR0aW5nc18QGXNob3dzSW5Ob3RpZmljYXRpb25DZW50ZXJfEBNhbGxvd3NOb3RpZmljYXRpb25zXxAWc2hvd3NPbkV4dGVybmFsRGV2aWNlc18QFWNvbnRlbnRQcmV2aWV3U2V0dGluZ15jYXJQbGF5U2V0dGluZ18QEXNob3dzSW5Mb2NrU2NyZWVuWWFsZXJ0VHlwZRA/CQkJgAQJEAHSQkNERVokY2xhc3NuYW1lWCRjbGFzc2VzXxAVQkJTZWN0aW9uSW5mb1NldHRpbmdzokZHXxAVQkJTZWN0aW9uSW5mb1NldHRpbmdzWE5TT2JqZWN0V0xOUG9wdXDSQkNKS11CQlNlY3Rpb25JbmZvokxHXUJCU2VjdGlvbkluZm9fEA9OU0tleWVkQXJjaGl2ZXLRT1BUcm9vdIABAAgAEQAaACMALQAyADcAQABGAHMAigCfAKoAtADAAMUA4QDtAQMBCgEcATEBOQFWAV4BagF9AY8BnAGkAb8BwAHCAcMBxQHHAckBygHMAc4B0AHSAdQB1gHYAdoB3AHeAeACCQIcAikCRQJbAnQCjAKbAq8CuQK7ArwCvQK+AsACwQLDAsgC0wLcAvQC9wMPAxgDIAMlAzMDNgNEA1YDWQNeAAAAAAAAAgEAAAAAAAAAUQAAAAAAAAAAAAAAAAAAA2A="
}

func simulatorPrivacyIdentifierIsSafe(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 255, simulatorPrivacyASCIIAlphaNumeric(bytes[0]) else {
        return false
    }
    return bytes.allSatisfy {
        simulatorPrivacyASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E
    }
}

private func simulatorPrivacyASCIIAlphaNumeric(_ value: UInt8) -> Bool {
    (0x30...0x39).contains(value)
        || (0x41...0x5A).contains(value)
        || (0x61...0x7A).contains(value)
}
