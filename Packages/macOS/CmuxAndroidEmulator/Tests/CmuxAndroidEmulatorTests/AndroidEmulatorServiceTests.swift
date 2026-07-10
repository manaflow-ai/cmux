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

    @Test func missingADBStillListsLaunchableAVDs() async throws {
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
        #expect(snapshot.devices == [AndroidVirtualDevice(name: "Pixel_9_API_35", state: .stopped)])
    }

    @Test func launchValidatesNameAndUsesVendorExecutable() async throws {
        let installation = Self.installation
        let launcher = RecordingAndroidEmulatorLauncher()
        let commands = StubCommandRunner(results: [
            StubCommand(
                executable: installation.emulatorURL.path,
                arguments: ["-list-avds"]
            ): .success("Pixel_9_API_35\n"),
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
            sdkRootURL: installation.rootURL
        )])
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

    @Test func snapshotResolvesConnectedEmulatorNamesConcurrently() async throws {
        let commands = ConcurrentNameQueryCommandRunner(installation: Self.installation)
        let service = AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(Self.installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )

        let snapshotTask = Task { try await service.snapshot() }
        try await Task.sleep(for: .milliseconds(100))
        await commands.releaseNameQueries()
        _ = try await snapshotTask.value

        #expect(await commands.maximumConcurrentNameQueries == 2)
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
}

private actor RecordingAndroidEmulatorLauncher: AndroidEmulatorProcessLaunching {
    private(set) var requests: [LaunchRequest] = []

    func launch(executableURL: URL, avdName: String, sdkRootURL: URL) async throws {
        requests.append(LaunchRequest(
            executableURL: executableURL,
            avdName: avdName,
            sdkRootURL: sdkRootURL
        ))
    }
}

private actor ConcurrentNameQueryCommandRunner: CommandRunning {
    private let installation: AndroidSDKInstallation
    private var nameQueriesReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var activeNameQueries = 0
    private(set) var maximumConcurrentNameQueries = 0

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
            return .success("Pixel_9_API_35\nTablet_API_35\n")
        }
        if arguments == ["devices"] {
            return .success("List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n")
        }

        activeNameQueries += 1
        maximumConcurrentNameQueries = max(maximumConcurrentNameQueries, activeNameQueries)
        if !nameQueriesReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        activeNameQueries -= 1

        let serial = arguments[1]
        let avdName = serial == "emulator-5554" ? "Pixel_9_API_35" : "Tablet_API_35"
        return .success("\(avdName)\nOK\n")
    }

    func releaseNameQueries() {
        nameQueriesReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
