import Foundation
import Testing
@testable import CmuxNextPhone

/// The controls behind the phone tab's keyboard shortcuts (Simulator: Home, Rotate Left/Right,
/// Toggle Appearance, Toggle Software Keyboard): what each sends to the phone.
@MainActor
@Suite struct SimulatorShortcutControlsTests {
    let booted = PhoneDeviceID(mode: .simulator, raw: "6A05764C-FFD1-4B40-AA2E-AD27ADAC7A56")
    let sim = PhoneDeviceID(mode: .simulator, raw: "SIM-1")
    let pixel = PhoneDeviceID(mode: .emulator, raw: "Pixel_8_API_35")
    let adb = "/sdk/platform-tools/adb"

    func iosService(_ runner: FakePhoneRunner) throws -> PhoneService {
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl", "list"], PhoneCommandResult(status: 1))
        let backend = XcodePhoneBackend(runner: runner)
        return PhoneService(backend: backend, recorder: PhoneRecorder(backend: backend, root: temporaryFolder(), makeID: { "rec" }),
                            scratch: temporaryFolder())
    }

    /// One running emulator (Pixel_8_API_35 on 5554), as AndroidPhoneBackendTests knows it.
    func androidRunner() -> FakePhoneRunner {
        let runner = FakePhoneRunner()
        runner.answer(["/sdk/emulator/emulator", "-list-avds"], PhoneCommandResult(status: 0, stdout: Data("Pixel_8_API_35\n".utf8)))
        runner.answer([adb, "devices", "-l"], PhoneCommandResult(status: 0, stdout: Data("""
            List of devices attached
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1

            """.utf8)))
        runner.answer([adb, "-s", "emulator-5554", "emu", "avd", "name"], PhoneCommandResult(status: 0, stdout: Data("Pixel_8_API_35\r\nOK\r\n".utf8)))
        runner.answer([adb, "-s", "emulator-5554", "shell", "getprop", "ro.build.version.release"], PhoneCommandResult(status: 0, stdout: Data("15\n".utf8)))
        return runner
    }

    func androidService(_ runner: FakePhoneRunner) -> PhoneService {
        let backend = PlatformPhoneBackend(ios: XcodePhoneBackend(runner: runner),
                                           android: AndroidPhoneBackend(sdk: AndroidSDK(root: URL(fileURLWithPath: "/sdk")), runner: runner))
        return PhoneService(backend: backend, recorder: PhoneRecorder(backend: backend, root: temporaryFolder(), makeID: { "rec" }),
                            scratch: temporaryFolder())
    }

    @Test func toggleAppearanceReadsTheSimulatorsModeAndSendsTheOther() async throws {
        let runner = FakePhoneRunner()
        let phones = try iosService(runner)
        runner.answer(["simctl", "ui", booted.raw, "appearance"], PhoneCommandResult(status: 0, stdout: Data("light\n".utf8)))
        #expect(try await phones.toggleAppearance(booted) == .dark)
        #expect(runner.runs.last == ["simctl", "ui", booted.raw, "appearance", "dark"])
        runner.answer(["simctl", "ui", booted.raw, "appearance"], PhoneCommandResult(status: 0, stdout: Data("dark\n".utf8)))
        #expect(try await phones.toggleAppearance(booted) == .light)
        #expect(runner.runs.last == ["simctl", "ui", booted.raw, "appearance", "light"])
    }

    @Test func toggleAppearanceReadsAnEmulatorsNightMode() async throws {
        let runner = androidRunner()
        let phones = androidService(runner)
        runner.answer([adb, "-s", "emulator-5554", "shell", "cmd", "uimode", "night"],
                      PhoneCommandResult(status: 0, stdout: Data("Night mode: yes\n".utf8)))
        #expect(try await phones.toggleAppearance(pixel) == .light)
        #expect(runner.runs.last == [adb, "-s", "emulator-5554", "shell", "cmd", "uimode", "night", "no"])
    }

    /// The emulator console's `rotate` turns the screen a quarter turn clockwise.
    @Test func rotateRightIsOneQuarterTurnAndLeftIsThree() async throws {
        let runner = androidRunner()
        let phones = androidService(runner)
        try await phones.rotate(pixel, .right)
        #expect(runner.runs.filter { $0.suffix(2) == ["emu", "rotate"] }.count == 1)
        try await phones.rotate(pixel, .left)
        #expect(runner.runs.filter { $0.suffix(2) == ["emu", "rotate"] }.count == 4)
    }

    @Test func theSoftwareKeyboardToggleGoesToTheSimulatorsHID() async throws {
        let hid = FakeSimulatorHID()
        try await XcodePhoneBackend(runner: FakePhoneRunner(), hid: hid).send(.softwareKeyboard, to: sim)
        #expect(hid.sent == [.softwareKeyboard])
    }

    @Test func homeIsTheHomeButton() async throws {
        let hid = FakeSimulatorHID()
        try await XcodePhoneBackend(runner: FakePhoneRunner(), hid: hid).send(.button(.home), to: sim)
        #expect(hid.sent == [.button(page: 0x0C, usage: 0x40)])
    }
}
