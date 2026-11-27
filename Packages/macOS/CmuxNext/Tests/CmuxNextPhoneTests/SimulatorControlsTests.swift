import Foundation
import Testing
@testable import CmuxNextPhone

/// The device controls the simulator pane adds on iOS (simctl) and the one
/// backend that routes each phone to its platform.
@Suite struct SimulatorControlsTests {
    let sim = PhoneDeviceID(mode: .simulator, raw: "SIM-1")

    @Test func iosAppearanceLocationInstallLaunchAndLocale() async throws {
        let runner = FakePhoneRunner()
        let backend = XcodePhoneBackend(runner: runner)
        try await backend.send(.appearance(.dark), to: sim)
        try await backend.send(.location(latitude: 37.33, longitude: -122.03), to: sim)
        try await backend.send(.install(URL(fileURLWithPath: "/tmp/My.app")), to: sim)
        try await backend.send(.launch("com.example.app"), to: sim)
        try await backend.send(.locale("ja_JP"), to: sim)
        #expect(runner.runs == [
            ["simctl", "ui", "SIM-1", "appearance", "dark"],
            ["simctl", "location", "SIM-1", "set", "37.33,-122.03"],
            ["simctl", "install", "SIM-1", "/tmp/My.app"],
            ["simctl", "launch", "SIM-1", "com.example.app"],
            ["simctl", "spawn", "SIM-1", "defaults", "write", "-g", "AppleLanguages", "-array", "ja"],
            ["simctl", "spawn", "SIM-1", "defaults", "write", "-g", "AppleLocale", "-string", "ja_JP"],
        ])
    }

    @Test func iosSimulatorsOfferTheControlsTheirBackendCanDo() {
        let device = PhoneDevice(id: sim, name: "iPhone", model: "iPhone 17", osVersion: "iOS 26.5", state: .ready)
        let caps = XcodePhoneBackend(runner: FakePhoneRunner()).capabilities(for: device)
        #expect(caps.isSuperset(of: [.appearance, .location, .apps, .locale]))
    }

    @Test func oneBackendRoutesEachPhoneToItsPlatform() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl"], PhoneCommandResult(status: 1))
        runner.answer(["/sdk/emulator/emulator", "-list-avds"], PhoneCommandResult(status: 0, stdout: Data("Pixel_8\n".utf8)))
        runner.answer(["/sdk/platform-tools/adb", "devices", "-l"], PhoneCommandResult(status: 0, stdout: Data("List of devices attached\n".utf8)))
        let backend = PlatformPhoneBackend(ios: XcodePhoneBackend(runner: runner),
                                           android: AndroidPhoneBackend(sdk: AndroidSDK(root: URL(fileURLWithPath: "/sdk")), runner: runner))
        let phones = try await backend.devices()
        #expect(phones.filter { $0.mode == .simulator }.count == 5)
        #expect(phones.filter { $0.mode == .emulator }.map(\.name) == ["Pixel 8"])
        try await backend.send(.appearance(.light), to: sim)
        #expect(runner.runs.last == ["simctl", "ui", "SIM-1", "appearance", "light"])
    }

    @Test func withoutAnAndroidSDKOnlyApplePhonesAreListedAndTheReasonIsKnown() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl"], PhoneCommandResult(status: 1))
        let backend = PlatformPhoneBackend(ios: XcodePhoneBackend(runner: runner), android: nil)
        #expect(try await backend.devices().allSatisfy { $0.mode == .simulator })
        #expect(await backend.missingTools == [.androidSDK])
        await #expect(throws: PhoneError.missingTool(.androidSDK)) {
            try await backend.boot(PhoneDeviceID(mode: .emulator, raw: "Pixel_8"))
        }
    }

    @Test func withoutXcodeTheReasonIsKnownAndAndroidStillWorks() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl"], PhoneCommandResult(status: 72, stderr: "xcrun: error: unable to find utility \"simctl\""))
        runner.answer(["/sdk/emulator/emulator", "-list-avds"], PhoneCommandResult(status: 0, stdout: Data("Pixel_8\n".utf8)))
        runner.answer(["/sdk/platform-tools/adb", "devices", "-l"], PhoneCommandResult(status: 0, stdout: Data("List of devices attached\n".utf8)))
        let backend = PlatformPhoneBackend(ios: XcodePhoneBackend(runner: runner),
                                           android: AndroidPhoneBackend(sdk: AndroidSDK(root: URL(fileURLWithPath: "/sdk")), runner: runner))
        #expect(try await backend.devices().map(\.id.description) == ["avd:Pixel_8"])
        #expect(await backend.missingTools == [.xcode])
    }
}
