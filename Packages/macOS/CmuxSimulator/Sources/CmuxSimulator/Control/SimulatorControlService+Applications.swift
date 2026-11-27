import Foundation

extension SimulatorControlService {
    /// Restores camera authorization journals whose exact owner process no
    /// longer exists. Recovery is serialized with camera injection, and the
    /// record is re-read under the cross-process TCC/application locks so a
    /// newly active worker can adopt it without being rolled back.
    public func recoverOrphanedCameraAuthorizations() async -> Bool {
        let scan: (
            records: [SimulatorCameraAuthorizationRecord],
            hadFailures: Bool
        )
        do {
            scan = try await cameraAuthorizationStore.records()
        } catch {
            return false
        }
        var tasks: [Task<SimulatorCameraCleanupResult, Never>] = []
        for record in scan.records where !record.isOwnedByRunningProcess {
            let task = await cameraCleanupCoordinator.enqueue(
                deviceIdentifier: record.deviceIdentifier,
                bundleIdentifiers: [record.bundleIdentifier]
            ) { [self] in
                do {
                    try await recoverCameraAuthorizationIfOrphaned(
                        deviceIdentifier: record.deviceIdentifier,
                        bundleIdentifier: record.bundleIdentifier
                    )
                    return .completed
                } catch is CancellationError {
                    return .failed(simulatorCameraCleanupCancellationFailure())
                } catch let error as SimulatorControlError {
                    return .failed(SimulatorFailure(
                        code: error.code,
                        message: error.message,
                        isRecoverable: true
                    ))
                } catch {
                    return .failed(SimulatorFailure(
                        code: "simulator_camera_cleanup_failed",
                        message: error.localizedDescription,
                        isRecoverable: true
                    ))
                }
            }
            tasks.append(task)
        }
        var succeeded = !scan.hadFailures
        for task in tasks {
            if case .failed = await task.value {
                succeeded = false
            }
        }
        return succeeded
    }

    /// Lists installed user and system applications.
    public func listApplications(deviceID: String) async throws -> [SimulatorInstalledApplication] {
        let arguments = ["simctl", "listapps", deviceID]
        let data = try await output(arguments: arguments)
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw SimulatorControlError(
                code: "invalid_application_list",
                arguments: arguments,
                message: String.localizedStringWithFormat(
                    String(
                        localized: "simulator.control.applicationListUnreadable",
                        defaultValue: "Xcode returned an unreadable installed-application list: %@"
                    ),
                    String(describing: error)
                )
            )
        }
        guard let records = value as? [String: [String: Any]] else {
            throw SimulatorControlError(
                code: "invalid_application_list",
                arguments: arguments,
                message: String(
                    localized: "simulator.control.applicationListUnexpected",
                    defaultValue: "Xcode returned an unexpected installed-application list."
                )
            )
        }
        return records.map { bundleIdentifier, record in
            SimulatorInstalledApplication(
                id: bundleIdentifier,
                name: record["CFBundleName"] as? String ?? bundleIdentifier,
                displayName: record["CFBundleDisplayName"] as? String
                    ?? record["CFBundleName"] as? String
                    ?? bundleIdentifier,
                executableName: record["CFBundleExecutable"] as? String ?? "",
                path: record["Path"] as? String ?? "",
                applicationType: record["ApplicationType"] as? String ?? "Unknown"
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Installs an application bundle or archive.
    public func installApplication(deviceID: String, applicationURL: URL) async throws {
        _ = try await output(arguments: ["simctl", "install", deviceID, applicationURL.path])
    }

    /// Launches an application and returns the process identifier when Xcode prints one.
    public func launchApplication(
        deviceID: String,
        bundleIdentifier: String,
        configuration: SimulatorLaunchConfiguration = SimulatorLaunchConfiguration()
    ) async throws -> Int32? {
        var arguments = ["simctl", "launch"]
        if configuration.waitForDebugger { arguments.append("--wait-for-debugger") }
        if configuration.terminateRunningProcess { arguments.append("--terminate-running-process") }
        arguments += [deviceID, bundleIdentifier]
        arguments += configuration.arguments

        let invalidKey = configuration.environment.keys.first { !isValidEnvironmentKey($0) }
        if let invalidKey {
            throw SimulatorControlError(
                code: "invalid_environment_key",
                arguments: arguments,
                message: String(
                    localized: "simulator.control.environmentKeyInvalid",
                    defaultValue: "The application environment key '\(invalidKey)' is invalid."
                )
            )
        }
        let environment = Dictionary(uniqueKeysWithValues: configuration.environment.map {
            ("SIMCTL_CHILD_\($0.key)", $0.value)
        })
        return try await mutationGate.withLocks([
            .application(deviceIdentifier: deviceID, bundleIdentifier: bundleIdentifier),
        ]) {
            let data: Data
            data = try await output(arguments: arguments, environment: environment)
            let commandOutput = String(decoding: data, as: UTF8.self)
            return commandOutput.split(whereSeparator: { !$0.isNumber })
                .last.flatMap { Int32($0) }
        }
    }

    /// Terminates a running application by bundle identifier.
    public func terminateApplication(deviceID: String, bundleIdentifier: String) async throws {
        try await mutationGate.withLocks([
            .tcc(deviceIdentifier: deviceID),
            .application(deviceIdentifier: deviceID, bundleIdentifier: bundleIdentifier),
        ]) {
            _ = try await output(arguments: [
                "simctl", "terminate", deviceID, bundleIdentifier,
            ])
        }
    }

    func cleanupCameraApplication(
        deviceID: String,
        bundleIdentifier: String,
        ownershipToken: UUID
    ) async throws {
        try await mutationGate.withLocks([
            .tcc(deviceIdentifier: deviceID),
            .application(deviceIdentifier: deviceID, bundleIdentifier: bundleIdentifier),
        ]) {
            let components = [deviceID, bundleIdentifier]
            guard cameraCleanupOwnershipStore.isCurrent(
                ownershipToken,
                namespace: "camera",
                components: components
            ) else { return }
            _ = try? await output(arguments: [
                "simctl", "terminate", deviceID, bundleIdentifier,
            ])
            guard cameraCleanupOwnershipStore.isCurrent(
                ownershipToken,
                namespace: "camera",
                components: components
            ) else { return }
            try await restoreCameraAuthorizationIfRecorded(
                deviceIdentifier: deviceID,
                bundleIdentifier: bundleIdentifier
            )
            guard cameraCleanupOwnershipStore.isCurrent(
                ownershipToken,
                namespace: "camera",
                components: components
            ) else { return }
            _ = try await output(arguments: [
                "simctl", "launch", "--terminate-running-process", deviceID, bundleIdentifier,
            ])
        }
    }

    private func recoverCameraAuthorizationIfOrphaned(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) async throws {
        try await mutationGate.withLocks([
            .tcc(deviceIdentifier: deviceIdentifier),
            .application(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            ),
        ]) {
            guard let record = try await cameraAuthorizationStore.record(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            ), !record.isOwnedByRunningProcess else { return }
            _ = try? await output(arguments: [
                "simctl", "terminate", deviceIdentifier, bundleIdentifier,
            ])
            guard let currentRecord = try await cameraAuthorizationStore.record(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            ), !currentRecord.isOwnedByRunningProcess else { return }
            try await restoreCameraAuthorizationIfRecorded(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            _ = try await output(arguments: [
                "simctl", "launch", "--terminate-running-process",
                deviceIdentifier, bundleIdentifier,
            ])
        }
    }

    private func restoreCameraAuthorizationIfRecorded(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) async throws {
        guard let authorization = try await cameraAuthorizationStore.authorization(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        ) else { return }
        let action: String = switch authorization {
        case .notDetermined: "reset"
        case .denied: "revoke"
        case .granted: "grant"
        default:
            throw SimulatorControlError(
                code: "camera_authorization_snapshot_invalid",
                arguments: [],
                message: String(
                    localized: "simulator.failure.cameraAuthorizationRestore",
                    defaultValue: "The saved Simulator camera authorization could not be restored."
                )
            )
        }
        _ = try await output(arguments: [
            "simctl", "privacy", deviceIdentifier, action, "camera", bundleIdentifier,
        ])
        try await cameraAuthorizationStore.remove(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }

    /// Opens a URL through the selected simulated operating system.
    public func openURL(deviceID: String, url: URL) async throws {
        _ = try await output(arguments: ["simctl", "openurl", deviceID, url.absoluteString])
    }

    /// Adds photos, videos, Live Photo pairs, or contacts to a device.
    public func addMedia(deviceID: String, urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        _ = try await output(arguments: ["simctl", "addmedia", deviceID] + urls.map(\.path))
    }

    /// Reads plain text from the simulated pasteboard.
    public func clipboardText(deviceID: String) async throws -> String {
        let arguments = ["simctl", "pbpaste", deviceID]
        let result = try await boundedOutput(
            arguments: arguments,
            standardOutputLimit: Self.maximumClipboardBytes
        )
        guard !result.outputWasTruncated else {
            throw SimulatorControlError(
                code: "clipboard_output_too_large",
                arguments: arguments,
                message: String(
                    localized: "simulator.clipboard.outputTooLarge",
                    defaultValue: "The Simulator clipboard is larger than 1 MiB."
                )
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    /// Replaces the simulated pasteboard with plain text.
    ///
    /// `simctl pbcopy` accepts its payload only on standard input. A private
    /// temporary file plus positional shell arguments preserves arbitrary text
    /// without interpolating user data into shell source.
    public func setClipboardText(_ text: String, deviceID: String) async throws {
        let arguments = ["simctl", "pbcopy", deviceID]
        guard text.utf8.count <= Self.maximumClipboardBytes else {
            throw SimulatorControlError(
                code: "clipboard_input_too_large",
                arguments: arguments,
                message: String(
                    localized: "simulator.clipboard.inputTooLarge",
                    defaultValue: "Clipboard text must be 1 MiB or smaller."
                )
            )
        }
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-simulator-paste-\(makeUUID().uuidString)")
        let created = fileManager.createFile(
            atPath: url.path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw SimulatorControlError(
                code: "clipboard_staging_failed",
                arguments: arguments,
                message: String(
                    localized: "simulator.control.clipboardStagingFailed",
                    defaultValue: "cmux could not create a private clipboard staging file."
                )
            )
        }
        defer { try? fileManager.removeItem(at: url) }

        let shellSource = "exec /usr/bin/xcrun simctl pbcopy \"$1\" < \"$2\""
        _ = try await output(
            executable: "/bin/sh",
            arguments: ["-c", shellSource, "cmux-simulator-pbcopy", deviceID, url.path],
            diagnosticArguments: ["simctl", "pbcopy", deviceID]
        )
    }

    /// Copies the host pasteboard onto the simulated device, including non-text items.
    public func syncClipboardFromHost(deviceID: String) async throws {
        _ = try await output(arguments: ["simctl", "pbsync", "host", deviceID])
    }

    /// Delivers a JSON Apple Push Notification payload file.
    public func sendPushNotification(
        deviceID: String,
        bundleIdentifier: String,
        payloadURL: URL
    ) async throws {
        _ = try await output(arguments: [
            "simctl", "push", deviceID, bundleIdentifier, payloadURL.path,
        ])
    }

    func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        return key.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}
