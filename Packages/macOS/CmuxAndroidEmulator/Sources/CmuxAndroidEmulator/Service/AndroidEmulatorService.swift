public import CmuxFoundation
import Foundation

/// Android SDK adapter that lists, launches, and stops user-installed AVDs.
public actor AndroidEmulatorService: AndroidEmulatorServicing {
    private let sdkLocator: any AndroidSDKLocating
    private let commands: any CommandRunning
    private let processLauncher: any AndroidEmulatorProcessLaunching

    /// Creates an Android emulator service from injected machine boundaries.
    ///
    /// - Parameters:
    ///   - sdkLocator: Discovers the user's Android SDK executables.
    ///   - commands: Runs short-lived vendor commands.
    ///   - processLauncher: Starts long-lived vendor emulator windows.
    public init(
        sdkLocator: any AndroidSDKLocating,
        commands: any CommandRunning,
        processLauncher: any AndroidEmulatorProcessLaunching
    ) {
        self.sdkLocator = sdkLocator
        self.commands = commands
        self.processLauncher = processLauncher
    }

    /// Reads installed AVDs and maps connected emulator serials back to AVD names.
    public func snapshot() async throws -> AndroidEmulatorSnapshot {
        let installation = try resolvedInstallation()
        let avdNames = try await availableAVDNames(using: installation)

        guard let adbURL = installation.adbURL else {
            return AndroidEmulatorSnapshot(
                sdkRootURL: installation.rootURL,
                devices: avdNames.map { AndroidVirtualDevice(name: $0, state: .stopped) },
                warning: .adbMissing
            )
        }

        let devicesResult = await commands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["devices"],
            timeout: 5
        )
        guard Self.succeeded(devicesResult) else {
            return AndroidEmulatorSnapshot(
                sdkRootURL: installation.rootURL,
                devices: avdNames.map { AndroidVirtualDevice(name: $0, state: .stopped) },
                warning: .adbQueryFailed(detail: Self.failureDetail(devicesResult))
            )
        }

        var runningByName: [String: AndroidVirtualDeviceState] = [:]
        for connected in Self.parseConnectedEmulators(devicesResult.stdout ?? "") {
            let nameResult = await commands.run(
                directory: installation.rootURL.path,
                executable: adbURL.path,
                arguments: ["-s", connected.serial, "emu", "avd", "name"],
                timeout: 3
            )
            guard Self.succeeded(nameResult),
                  let avdName = Self.parseAVDName(nameResult.stdout ?? "") else {
                continue
            }
            runningByName[avdName] = .running(
                serial: connected.serial,
                connectionState: connected.connectionState
            )
        }

        let allNames = Set(avdNames).union(runningByName.keys)
        let devices = allNames
            .map { name in
                AndroidVirtualDevice(name: name, state: runningByName[name] ?? .stopped)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return AndroidEmulatorSnapshot(
            sdkRootURL: installation.rootURL,
            devices: devices,
            warning: nil
        )
    }

    /// Validates the AVD against the installed emulator before spawning it.
    public func launch(avdName: String) async throws {
        let installation = try resolvedInstallation()
        let avdNames = try await availableAVDNames(using: installation)
        guard avdNames.contains(avdName) else {
            throw AndroidEmulatorError.avdNotFound(name: avdName)
        }
        try await processLauncher.launch(
            executableURL: installation.emulatorURL,
            avdName: avdName,
            sdkRootURL: installation.rootURL
        )
    }

    /// Stops a running emulator through its installed Android Debug Bridge.
    public func stop(serial: String) async throws {
        guard serial.hasPrefix("emulator-"),
              serial.dropFirst("emulator-".count).allSatisfy(\.isNumber) else {
            throw AndroidEmulatorError.invalidEmulatorSerial(serial)
        }

        let installation = try resolvedInstallation()
        guard let adbURL = installation.adbURL else {
            throw AndroidEmulatorError.adbMissing(sdkPath: installation.rootURL.path)
        }
        let result = await commands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["-s", serial, "emu", "kill"],
            timeout: 5
        )
        guard Self.succeeded(result) else {
            throw AndroidEmulatorError.commandFailed(tool: "adb", detail: Self.failureDetail(result))
        }
    }

    private func resolvedInstallation() throws -> AndroidSDKInstallation {
        switch sdkLocator.locate() {
        case .available(let installation):
            return installation
        case .emulatorMissing(let rootURL):
            throw AndroidEmulatorError.emulatorMissing(sdkPath: rootURL.path)
        case .sdkNotFound:
            throw AndroidEmulatorError.sdkNotFound
        }
    }

    private func availableAVDNames(using installation: AndroidSDKInstallation) async throws -> [String] {
        let result = await commands.run(
            directory: installation.rootURL.path,
            executable: installation.emulatorURL.path,
            arguments: ["-list-avds"],
            timeout: 5
        )
        guard Self.succeeded(result) else {
            throw AndroidEmulatorError.commandFailed(tool: "emulator", detail: Self.failureDetail(result))
        }
        return Self.parseAVDNames(result.stdout ?? "")
    }

    static func parseAVDNames(_ output: String) -> [String] {
        var seen: Set<String> = []
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func parseConnectedEmulators(_ output: String) -> [(serial: String, connectionState: String)] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (String, String)? in
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 2, fields[0].hasPrefix("emulator-") else { return nil }
                return (fields[0], fields[1])
            }
    }

    static func parseAVDName(_ output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    private static func succeeded(_ result: CommandResult) -> Bool {
        result.executionError == nil && !result.timedOut && result.exitStatus == 0
    }

    private static func failureDetail(_ result: CommandResult) -> String {
        if let executionError = result.executionError { return executionError }
        if result.timedOut { return "timeout" }
        if let stderr = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines), !stderr.isEmpty {
            return stderr
        }
        if let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !stdout.isEmpty {
            return stdout
        }
        return "exit_status=\(result.exitStatus.map(String.init) ?? "unknown")"
    }
}
