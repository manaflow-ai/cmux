@testable import CmuxAndroidEmulator
import CmuxFoundation
import Foundation
import Testing

@Suite struct AndroidEmulatorServiceControlTests {
    @Test func parsesOverrideDisplaySize() {
        let size = AndroidEmulatorService.parseDisplaySize(
            "Physical size: 1080x2424\nOverride size: 720x1280\n"
        )

        #expect(size == AndroidEmulatorDisplaySize(width: 720, height: 1280))
    }

    @Test func homeControlRevalidatesTransportAndAVDIdentity() async throws {
        let commands = StubCommandRunner(results: Self.validatedResults.merging([
            Self.command(["-t", "42", "shell", "input", "keyevent", "3"]): .success(""),
        ]) { _, latest in latest })
        let service = Self.makeService(commands: commands)

        try await service.perform(
            AndroidEmulatorControlAction.home,
            avdName: "Pixel_9_API_35",
            serial: "emulator-5554",
            transportID: "42"
        )

        #expect(await commands.invocations.map { $0.arguments } == [
            ["devices", "-l"],
            ["-t", "42", "emu", "avd", "name"],
            ["-t", "42", "shell", "input", "keyevent", "3"],
        ])
    }

    @Test func controlRejectsReplacementTransportBeforeSendingInput() async {
        let commands = StubCommandRunner(results: [
            Self.command(["devices", "-l"]): .success(
                "List of devices attached\nemulator-5554 device transport_id:43\n"
            ),
        ])
        let service = Self.makeService(commands: commands)

        await #expect(throws: AndroidEmulatorError.stopNotConfirmed(serial: "emulator-5554")) {
            try await service.perform(
                AndroidEmulatorControlAction.back,
                avdName: "Pixel_9_API_35",
                serial: "emulator-5554",
                transportID: "42"
            )
        }
        #expect(await commands.invocations.map { $0.arguments } == [["devices", "-l"]])
    }

    private static let installation = AndroidSDKInstallation(
        rootURL: URL(fileURLWithPath: "/sdk", isDirectory: true),
        emulatorURL: URL(fileURLWithPath: "/sdk/emulator/emulator"),
        adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb")
    )

    private static let validatedResults: [StubCommand: CommandResult] = [
        command(["devices", "-l"]): .success(
            "List of devices attached\nemulator-5554 device transport_id:42\n"
        ),
        command(["-t", "42", "emu", "avd", "name"]): .success("Pixel_9_API_35\nOK\n"),
    ]

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
