@testable import CmuxAndroidEmulator
import CmuxFoundation
import Foundation
import Testing

@Suite struct AndroidEmulatorServiceLifecycleTests {
    @Test func adbRunnerDoesNotWaitForDescendantHoldingOutputOpen() async {
        let runner = AndroidADBCommandRunner(environment: ProcessInfo.processInfo.environment)
        let clock = ContinuousClock()
        let started = clock.now

        let result = await runner.run(
            directory: "/tmp",
            executable: "/bin/sh",
            arguments: ["-c", "(sleep 2) & printf ok"],
            timeout: 0.5
        )

        #expect(result.timedOut == false)
        #expect(result.stdout == "ok")
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test func stopIsIdempotentWhenTransportIsAlreadyAbsent() async throws {
        let commands = StubCommandRunner(results: [
            Self.command(["devices", "-l"]): .success("List of devices attached\n"),
        ])
        let service = Self.makeService(commands: commands)

        try await service.stop(
            avdName: "Pixel_9_API_35",
            serial: "emulator-5554",
            transportID: "42"
        )

        #expect(await commands.invocations.map { $0.arguments } == [["devices", "-l"]])
    }

    @Test func stopReportsADBQueryFailureInsteadOfClaimingEmulatorStillRuns() async {
        let commands = StubCommandRunner(results: [
            Self.command(["devices", "-l"]): CommandResult(
                stdout: nil,
                stderr: "adb server unavailable",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            ),
        ])
        let service = Self.makeService(commands: commands)

        await #expect(throws: AndroidEmulatorError.commandFailed(
            tool: "adb",
            detail: "adb server unavailable"
        )) {
            try await service.stop(
                avdName: "Pixel_9_API_35",
                serial: "emulator-5554",
                transportID: "42"
            )
        }
    }

    private static let installation = AndroidSDKInstallation(
        rootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        emulatorURL: URL(fileURLWithPath: "/sdk/emulator/emulator"),
        adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb")
    )

    private static func command(_ arguments: [String]) -> StubCommand {
        StubCommand(executable: installation.adbURL!.path, arguments: arguments)
    }

    private static func makeService(commands: StubCommandRunner) -> AndroidEmulatorService {
        AndroidEmulatorService(
            sdkLocator: StubSDKLocator(resolution: .available(installation)),
            commands: commands,
            processLauncher: RecordingAndroidEmulatorLauncher()
        )
    }
}
