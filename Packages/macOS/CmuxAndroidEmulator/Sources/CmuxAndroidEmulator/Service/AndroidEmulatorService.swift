public import CmuxFoundation
import Foundation

/// Android SDK adapter that lists, launches, and stops user-installed AVDs.
public actor AndroidEmulatorService: AndroidEmulatorServicing {
    private static let maximumConcurrentNameQueries = 4

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
                devices: avdNames.map { AndroidVirtualDevice(name: $0, state: .unavailable) },
                warning: .adbMissing,
                connectedEmulatorSerials: nil
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
                devices: avdNames.map { AndroidVirtualDevice(name: $0, state: .unavailable) },
                warning: .adbQueryFailed(detail: Self.failureDetail(devicesResult)),
                connectedEmulatorSerials: nil
            )
        }

        let connectedEmulators = Self.parseConnectedEmulators(devicesResult.stdout ?? "")
        let connectedEmulatorSerials = Set(connectedEmulators.map(\.serial))
        let commands = self.commands
        let identityResolution = await withTaskGroup(
            of: Result<[String: AndroidVirtualDeviceState], AndroidEmulatorError>.self,
            returning: ([String: AndroidVirtualDeviceState], String?).self
        ) { group in
            var pending = connectedEmulators.makeIterator()
            for _ in 0..<min(Self.maximumConcurrentNameQueries, connectedEmulators.count) {
                guard let connected = pending.next() else { break }
                group.addTask {
                    await Self.resolveConnectedEmulator(
                        connected,
                        installation: installation,
                        adbURL: adbURL,
                        commands: commands
                    )
                }
            }

            var resolved: [String: AndroidVirtualDeviceState] = [:]
            var firstFailureDetail: String?
            while let result = await group.next() {
                switch result {
                case .success(let device):
                    resolved.merge(device) { _, latest in latest }
                case .failure(.commandFailed(_, let detail)):
                    firstFailureDetail = firstFailureDetail ?? detail
                case .failure(let error):
                    firstFailureDetail = firstFailureDetail ?? String(describing: error)
                }

                if let connected = pending.next() {
                    group.addTask {
                        await Self.resolveConnectedEmulator(
                            connected,
                            installation: installation,
                            adbURL: adbURL,
                            commands: commands
                        )
                    }
                }
            }
            return (resolved, firstFailureDetail)
        }

        let runningByName = identityResolution.0
        let fallbackState: AndroidVirtualDeviceState = identityResolution.1 == nil ? .stopped : .unavailable
        let allNames = Set(avdNames).union(runningByName.keys)
        let devices = allNames
            .map { name in
                AndroidVirtualDevice(name: name, state: runningByName[name] ?? fallbackState)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return AndroidEmulatorSnapshot(
            sdkRootURL: installation.rootURL,
            devices: devices,
            warning: identityResolution.1.map(AndroidEmulatorWarning.adbQueryFailed),
            connectedEmulatorSerials: connectedEmulatorSerials
        )
    }

    /// Validates the AVD against the installed emulator before spawning it.
    public func launch(avdName: String) async throws {
        let installation = try resolvedInstallation()
        let avdNames = try await availableAVDNames(using: installation)
        guard avdNames.contains(avdName) else {
            throw AndroidEmulatorError.avdNotFound(name: avdName)
        }
        guard let adbURL = installation.adbURL else {
            throw AndroidEmulatorError.adbMissing(sdkPath: installation.rootURL.path)
        }

        let devicesResult = await commands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["devices"],
            timeout: 5
        )
        guard Self.succeeded(devicesResult) else {
            throw AndroidEmulatorError.commandFailed(tool: "adb", detail: Self.failureDetail(devicesResult))
        }
        guard let consolePort = Self.firstAvailableConsolePort(devicesResult.stdout ?? "") else {
            throw AndroidEmulatorError.launchFailed(detail: "No Android emulator console port is available.")
        }

        let processID = try await processLauncher.launch(
            executableURL: installation.emulatorURL,
            avdName: avdName,
            sdkRootURL: installation.rootURL,
            consolePort: consolePort
        )
        let serial = "emulator-\(consolePort)"
        let waitResult = await commands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["-s", serial, "wait-for-device"],
            timeout: 30
        )
        guard Self.succeeded(waitResult) else {
            await processLauncher.terminate(processID: processID)
            throw AndroidEmulatorError.launchNotConfirmed(name: avdName)
        }

        let nameResult = await commands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["-s", serial, "emu", "avd", "name"],
            timeout: 3
        )
        guard Self.succeeded(nameResult), Self.parseAVDName(nameResult.stdout ?? "") == avdName else {
            await processLauncher.terminate(processID: processID)
            throw AndroidEmulatorError.launchNotConfirmed(name: avdName)
        }
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
        guard Self.consoleCommandSucceeded(result) else {
            throw AndroidEmulatorError.commandFailed(tool: "adb", detail: Self.failureDetail(result))
        }

        let disconnectResult = await commands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["-s", serial, "wait-for-disconnect"],
            timeout: 15
        )
        guard Self.succeeded(disconnectResult) else {
            let devicesResult = await commands.run(
                directory: installation.rootURL.path,
                executable: adbURL.path,
                arguments: ["devices"],
                timeout: 5
            )
            let connectedSerials = Set(Self.parseConnectedEmulators(devicesResult.stdout ?? "").map(\.serial))
            guard Self.succeeded(devicesResult), !connectedSerials.contains(serial) else {
                throw AndroidEmulatorError.stopNotConfirmed(serial: serial)
            }
            return
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
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              lines.last == "OK",
              let name = lines.first,
              !Self.isConsoleErrorLine(name) else {
            return nil
        }
        return name
    }

    private static func firstAvailableConsolePort(_ devicesOutput: String) -> Int? {
        let occupiedSerials = Set(parseConnectedEmulators(devicesOutput).map(\.serial))
        return stride(from: 5554, through: 5682, by: 2)
            .first { !occupiedSerials.contains("emulator-\($0)") }
    }

    private static func resolveConnectedEmulator(
        _ connected: (serial: String, connectionState: String),
        installation: AndroidSDKInstallation,
        adbURL: URL,
        commands: any CommandRunning
    ) async -> Result<[String: AndroidVirtualDeviceState], AndroidEmulatorError> {
        let nameResult = await commands.run(
            directory: installation.rootURL.path,
            executable: adbURL.path,
            arguments: ["-s", connected.serial, "emu", "avd", "name"],
            timeout: 3
        )
        guard succeeded(nameResult),
              let avdName = parseAVDName(nameResult.stdout ?? "") else {
            return .failure(.commandFailed(tool: "adb", detail: failureDetail(nameResult)))
        }
        return .success([avdName: .running(
            serial: connected.serial,
            connectionState: connected.connectionState
        )])
    }

    private static func succeeded(_ result: CommandResult) -> Bool {
        result.executionError == nil && !result.timedOut && result.exitStatus == 0
    }

    private static func consoleCommandSucceeded(_ result: CommandResult) -> Bool {
        guard succeeded(result) else { return false }
        let lines = [result.stdout, result.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return !lines.contains(where: isConsoleErrorLine)
    }

    private static func isConsoleErrorLine(_ line: String) -> Bool {
        let normalized = line.lowercased()
        return normalized.hasPrefix("ko:")
            || normalized.hasPrefix("error:")
            || normalized.hasPrefix("android console:")
            || normalized.hasPrefix("authentication required")
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
