@testable import CmuxAndroidEmulator
import CmuxFoundation
import Foundation

struct StubSDKLocator: AndroidSDKLocating {
    let resolution: AndroidSDKResolution

    func locate() -> AndroidSDKResolution { resolution }
}

struct StubCommand: Hashable, Sendable {
    let executable: String
    let arguments: [String]
}

actor StubCommandRunner: CommandRunning {
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

actor SequencedCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private(set) var invocations: [StubCommand] = []

    init(results: [CommandResult]) {
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
        invocations.append(StubCommand(executable: executable, arguments: arguments))
        guard !results.isEmpty else {
            return CommandResult(
                stdout: nil,
                stderr: "unexpected command",
                exitStatus: 127,
                timedOut: false,
                executionError: nil
            )
        }
        return results.removeFirst()
    }
}

extension CommandResult {
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

struct LaunchRequest: Sendable, Equatable {
    let executableURL: URL
    let avdName: String
    let sdkRootURL: URL
    let consolePort: Int
}

actor RecordingAndroidEmulatorLauncher: AndroidEmulatorProcessLaunching {
    static let processID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private(set) var requests: [LaunchRequest] = []
    private(set) var terminatedProcessIDs: [UUID] = []
    private let unavailableConsolePorts: Set<Int>

    init(unavailableConsolePorts: Set<Int> = []) {
        self.unavailableConsolePorts = unavailableConsolePorts
    }

    func consolePortPairIsAvailable(_ consolePort: Int) -> Bool {
        !unavailableConsolePorts.contains(consolePort)
            && !unavailableConsolePorts.contains(consolePort + 1)
    }

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

actor ConcurrentNameQueryCommandRunner: CommandRunning {
    private let installation: AndroidSDKInstallation
    private var nameQueriesReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var activeNameQueries = 0
    private(set) var maximumConcurrentNameQueries = 0
    private var nameQueryCountContinuation: AsyncStream<Int>.Continuation?

    init(installation: AndroidSDKInstallation) { self.installation = installation }

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
        if arguments == ["devices", "-l"] {
            let devices = (0..<6)
                .map { "emulator-\(5554 + ($0 * 2))\tdevice transport_id:\($0 + 1)" }
                .joined(separator: "\n")
            return .success("List of devices attached\n\(devices)\n")
        }

        activeNameQueries += 1
        maximumConcurrentNameQueries = max(maximumConcurrentNameQueries, activeNameQueries)
        nameQueryCountContinuation?.yield(activeNameQueries)
        if !nameQueriesReleased {
            await withCheckedContinuation { releaseContinuations.append($0) }
        }
        activeNameQueries -= 1

        let port = Int(arguments[1].dropFirst("emulator-".count)) ?? 5554
        return .success("Device_\((port - 5554) / 2)\nOK\n")
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
        for continuation in continuations { continuation.resume() }
        nameQueryCountContinuation?.finish()
        nameQueryCountContinuation = nil
    }
}

actor ConcurrentLaunchCommandRunner: CommandRunning {
    private let installation: AndroidSDKInstallation
    private var waitingConfirmationCount = 0
    private var waitCountContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(installation: AndroidSDKInstallation) { self.installation = installation }

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
        if arguments == ["devices"] { return .success("List of devices attached\n") }
        if arguments.last == "wait-for-device" {
            waitingConfirmationCount += 1
            if waitingConfirmationCount == 2 {
                waitCountContinuation?.resume()
                waitCountContinuation = nil
            }
            await withCheckedContinuation { releaseContinuations.append($0) }
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            )
        }
        return CommandResult(
            stdout: nil,
            stderr: "unexpected command",
            exitStatus: 127,
            timedOut: false,
            executionError: nil
        )
    }

    func waitUntilBothLaunchesAwaitConfirmation() async {
        if waitingConfirmationCount == 2 { return }
        await withCheckedContinuation { waitCountContinuation = $0 }
    }

    func releaseConfirmations() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
