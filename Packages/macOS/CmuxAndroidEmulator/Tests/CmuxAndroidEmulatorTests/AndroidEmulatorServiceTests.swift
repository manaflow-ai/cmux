@testable import CmuxAndroidEmulator
import CmuxFoundation
import Foundation
import Testing

@Suite struct AndroidEmulatorServiceTests {
    @Test func snapshotMapsConnectedSerialToInstalledAVD() async throws {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Tablet_API_35\nPixel_9_API_35\nPixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\nemulator-5554\tdevice\nphysical-1\tdevice\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): .success("Pixel_9_API_35\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.sdkRootURL == installation.rootURL)
        #expect(snapshot.warning == nil)
        #expect(snapshot.devices.map(\.name) == ["Pixel_9_API_35", "Tablet_API_35"])
        #expect(snapshot.devices[0].state == .running(serial: "emulator-5554", connectionState: "device"))
        #expect(snapshot.devices[1].state == .stopped)
    }

    @Test func missingADBMarksAVDStateUnavailable() async throws {
        let installation = AndroidSDKInstallation(
            rootURL: Self.installation.rootURL,
            emulatorURL: Self.installation.emulatorURL,
            adbURL: nil
        )
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.warning == .adbMissing)
        #expect(snapshot.devices == [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .unavailable)])
    }

    @Test func launchValidatesNameAndUsesVendorExecutable() async throws {
        let installation = Self.installation
        let launcher = RecordingAndroidEmulatorLauncher()
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "wait-for-device"]
            ): .success(""),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): .success("Pixel_9_API_35\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: launcher
        )

        try await service.launch(avdName: "Pixel_9_API_35")

        #expect(await launcher.requests == [LaunchRequest(
            executableURL: installation.emulatorURL,
            avdName: "Pixel_9_API_35",
            sdkRootURL: installation.rootURL,
            consolePort: 5554
        )])
    }

    @Test func snapshotRejectsConsoleErrorReturnedWithZeroExitStatus() async throws {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\nemulator-5554\tdevice\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): .success("KO: 'avd name' is currently unsupported\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.devices == [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .unavailable)])
        #expect(snapshot.warning != nil)
    }

    @Test func failedLaunchConfirmationTerminatesSpawnedProcess() async {
        let installation = Self.installation
        let launcher = RecordingAndroidEmulatorLauncher()
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "wait-for-device"]
            ): CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            ),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: launcher
        )

        await #expect(throws: AndroidEmulatorError.launchNotConfirmed(name: "Pixel_9_API_35")) {
            try await service.launch(avdName: "Pixel_9_API_35")
        }

        #expect(await launcher.terminatedProcessIDs == [RecordingAndroidEmulatorLauncher.processID])
    }

    @Test func stopRejectsPhysicalDeviceSerialBeforeRunningADB() async {
        let commands = StubCommandRunner(results: [:])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(Self.installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        await #expect(throws: AndroidEmulatorError.invalidEmulatorSerial("R58M123")) {
            try await service.stop(serial: "R58M123")
        }
        #expect(await commands.invocations.isEmpty)
    }

    @Test func stopRejectsConsoleErrorReturnedWithZeroExitStatus() async {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "kill"]
            ): .success("KO: emulator refused to stop\nOK\n"),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        await #expect(throws: AndroidEmulatorError.self) {
            try await service.stop(serial: "emulator-5554")
        }

        #expect(await commands.invocations.count == 1)
    }

    @Test func snapshotResolvesConnectedEmulatorNamesConcurrently() async throws {
        let commands = ConcurrentNameQueryCommandRunner(installation: Self.installation)
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(Self.installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let queryCounts = await commands.nameQueryCountStream()
        let snapshotTask = Task { try await service.snapshot() }
        let reachedWorkerLimit = await Self.waitForQueryCount(4, in: queryCounts)
        await commands.releaseNameQueries()
        _ = try await snapshotTask.value

        #expect(reachedWorkerLimit)
        #expect(await commands.maximumConcurrentNameQueries == 4)
    }

    @Test func unresolvedConnectedEmulatorMarksStoppedAVDsUnavailable() async throws {
        let installation = Self.installation
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\nTablet_API_35\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["devices"]
            ): .success("List of devices attached\nemulator-5554\toffline\n"),
            StubCommand(
                executable: installation.adbURL!.path,
                arguments: ["-s", "emulator-5554", "emu", "avd", "name"]
            ): CommandResult(
                stdout: "",
                stderr: "offline",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
        ])
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshot = try await service.snapshot()

        #expect(snapshot.devices.map(\.state) == [.unavailable, .unavailable])
        #expect(snapshot.warning == .adbQueryFailed(detail: "offline"))
    }

    private static func waitForQueryCount(
        _ expectedCount: Int,
        in counts: AsyncStream<Int>
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await count in counts where count >= expectedCount {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private static let installation = AndroidSDKInstallation(
        rootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        emulatorURL: URL(fileURLWithPath: "/sdk/emulator/emulator"),
        adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb")
    )
}

private struct StubSDKLocator: AndroidSDKLocating {
    let resolution: AndroidSDKResolution

    func locate() -> AndroidSDKResolution {
        resolution
    }
}

private struct StubCommand: Hashable, Sendable {
    let executable: String
    let arguments: [String]
}

private actor StubCommandRunner: CommandRunning {
    private let results: [StubCommand: CommandResult]
    private(set) var invocations: [StubCommand] = []

    init(results: [StubCommand: CommandResult]) {
        self.results = results
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        _ = directory
        _ = timeout
        let command = StubCommand(executable: executable, arguments: arguments)
        invocations.append(command)
        return results[command] ?? CommandResult(
            stdout: nil,
            stderr: "unexpected command",
            exitStatus: 127,
            timedOut: false,
            executionError: nil
        )
    }
}

private extension CommandResult {
    static func success(_ stdout: String) -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}

private struct LaunchRequest: Sendable, Equatable {
    let executableURL: URL
    let avdName: String
    let sdkRootURL: URL
    let consolePort: Int
}

private actor RecordingAndroidEmulatorLauncher: AndroidEmulatorProcessLaunching {
    static let processID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private(set) var requests: [LaunchRequest] = []
    private(set) var terminatedProcessIDs: [UUID] = []

    func launch(
        executableURL: URL,
        avdName: String,
        sdkRootURL: URL,
        consolePort: Int
    ) async throws -> UUID {
        requests.append(LaunchRequest(
            executableURL: executableURL,
            avdName: avdName,
            sdkRootURL: sdkRootURL,
            consolePort: consolePort
        ))
        return Self.processID
    }

    func terminate(processID: UUID) {
        terminatedProcessIDs.append(processID)
    }
}

private actor ConcurrentNameQueryCommandRunner: CommandRunning {
    private let installation: AndroidSDKInstallation
    private var nameQueriesReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var activeNameQueries = 0
    private(set) var maximumConcurrentNameQueries = 0
    private var nameQueryCountContinuation: AsyncStream<Int>.Continuation?

    init(installation: AndroidSDKInstallation) {
        self.installation = installation
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        _ = directory
        _ = timeout
        if executable == installation.emulatorURL.path {
            return .success((0..<6).map { "Device_\($0)" }.joined(separator: "\n") + "\n")
        }
        if arguments == ["devices"] {
            let devices = (0..<6)
                .map { "emulator-\(5554 + ($0 * 2))\tdevice" }
                .joined(separator: "\n")
            return .success("List of devices attached\n\(devices)\n")
        }

        activeNameQueries += 1
        maximumConcurrentNameQueries = max(maximumConcurrentNameQueries, activeNameQueries)
        nameQueryCountContinuation?.yield(activeNameQueries)
        if !nameQueriesReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        activeNameQueries -= 1

        let serial = arguments[1]
        let port = Int(serial.dropFirst("emulator-".count)) ?? 5554
        let avdName = "Device_\((port - 5554) / 2)"
        return .success("\(avdName)\nOK\n")
    }

    func nameQueryCountStream() -> AsyncStream<Int> {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        nameQueryCountContinuation = continuation
        continuation.yield(activeNameQueries)
        return stream
    }

    func releaseNameQueries() {
        nameQueriesReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
        nameQueryCountContinuation?.finish()
        nameQueryCountContinuation = nil
    }
}
