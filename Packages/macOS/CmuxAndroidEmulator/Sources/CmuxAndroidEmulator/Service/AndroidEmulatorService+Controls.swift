import CmuxFoundation
import Foundation

extension AndroidEmulatorService {
    /// Sends one control command only after the selected AVD and transport still match.
    public func perform(
        _ action: AndroidEmulatorControlAction,
        avdName: String,
        serial: String,
        transportID: String
    ) async throws {
        let installation = try resolvedInstallation()
        guard let adbURL = installation.adbURL else {
            throw AndroidEmulatorError.adbMissing(sdkPath: installation.rootURL.path)
        }
        try await validateTransport(
            avdName: avdName,
            serial: serial,
            transportID: transportID,
            installation: installation,
            adbURL: adbURL
        )

        let arguments = try await controlArguments(
            for: action,
            installation: installation,
            adbURL: adbURL,
            transportID: transportID
        )
        let result = await adbCommands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: arguments,
            timeout: 5
        )
        guard Self.succeeded(result) else {
            throw AndroidEmulatorError.commandFailed(tool: "adb", detail: Self.failureDetail(result))
        }
    }

    /// Reads `wm size` from the same validated transport used by the pane controls.
    public func displaySize(
        avdName: String,
        serial: String,
        transportID: String
    ) async throws -> AndroidEmulatorDisplaySize {
        let installation = try resolvedInstallation()
        guard let adbURL = installation.adbURL else {
            throw AndroidEmulatorError.adbMissing(sdkPath: installation.rootURL.path)
        }
        try await validateTransport(
            avdName: avdName,
            serial: serial,
            transportID: transportID,
            installation: installation,
            adbURL: adbURL
        )
        let result = await adbCommands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["-t", transportID, "shell", "wm", "size"],
            timeout: 5
        )
        guard Self.succeeded(result), let size = Self.parseDisplaySize(result.stdout ?? "") else {
            throw AndroidEmulatorError.commandFailed(tool: "adb", detail: Self.failureDetail(result))
        }
        return size
    }

    static func parseDisplaySize(_ output: String) -> AndroidEmulatorDisplaySize? {
        let candidate = output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .first(where: { $0.contains("x") })?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate else { return nil }
        let dimensions = candidate.split(separator: "x", maxSplits: 1)
        guard dimensions.count == 2,
              let width = Int(dimensions[0]),
              let height = Int(dimensions[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return AndroidEmulatorDisplaySize(width: width, height: height)
    }

    private func validateTransport(
        avdName: String,
        serial: String,
        transportID: String,
        installation: AndroidSDKInstallation,
        adbURL: URL
    ) async throws {
        let devicesResult = await adbCommands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["devices", "-l"],
            timeout: 5
        )
        guard Self.succeeded(devicesResult),
              Self.parseConnectedEmulators(devicesResult.stdout ?? "")
                .contains(where: { $0.serial == serial && $0.transportID == transportID }) else {
            throw AndroidEmulatorError.stopNotConfirmed(serial: serial)
        }

        let nameResult = await adbCommands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["-t", transportID, "emu", "avd", "name"],
            timeout: 3
        )
        guard Self.succeeded(nameResult), let currentName = Self.parseAVDName(nameResult.stdout ?? "") else {
            throw AndroidEmulatorError.commandFailed(tool: "adb", detail: Self.failureDetail(nameResult))
        }
        guard currentName == avdName else {
            throw AndroidEmulatorError.avdIdentityChanged(expected: avdName, actual: currentName)
        }
    }

    private func controlArguments(
        for action: AndroidEmulatorControlAction,
        installation: AndroidSDKInstallation,
        adbURL: URL,
        transportID: String
    ) async throws -> [String] {
        let prefix = ["-t", transportID, "shell", "input"]
        switch action {
        case .power: return prefix + ["keyevent", "26"]
        case .volumeUp: return prefix + ["keyevent", "24"]
        case .volumeDown: return prefix + ["keyevent", "25"]
        case .back: return prefix + ["keyevent", "4"]
        case .home: return prefix + ["keyevent", "3"]
        case .overview: return prefix + ["keyevent", "187"]
        case .tap(let x, let y):
            return prefix + ["tap", String(max(0, x)), String(max(0, y))]
        case .swipe(let fromX, let fromY, let toX, let toY, let duration):
            return prefix + [
                "swipe", String(max(0, fromX)), String(max(0, fromY)),
                String(max(0, toX)), String(max(0, toY)), String(max(1, duration)),
            ]
        case .rotateLeft, .rotateRight:
            let result = await adbCommands.run(
                directory: installation.rootURL.path,
                executable: adbURL.path,
                arguments: ["-t", transportID, "shell", "settings", "get", "system", "user_rotation"],
                timeout: 3
            )
            guard Self.succeeded(result) else {
                throw AndroidEmulatorError.commandFailed(tool: "adb", detail: Self.failureDetail(result))
            }
            let current = Int(result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let next = (current + (action == .rotateLeft ? 3 : 1)) % 4
            return [
                "-t", transportID, "shell", "sh", "-c",
                "settings put system accelerometer_rotation 0; settings put system user_rotation \(next)",
            ]
        }
    }
}
