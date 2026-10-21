import Foundation
import Testing
@testable import CmuxNextPhone

@Suite struct XcodePhoneBackendTests {
    let sim = PhoneDeviceID(mode: .simulator, raw: "SIM-1")
    let dev = PhoneDeviceID(mode: .device, raw: "DEV-1")

    @Test func listsSimulatorsAndRealDevicesTogether() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("devicectl-list")))
        let phones = try await XcodePhoneBackend(runner: runner).devices()
        #expect(phones.filter { $0.mode == .simulator }.count == 5)
        #expect(phones.filter { $0.mode == .device }.count == 2)
    }

    @Test func aMacWithoutDevicectlStillListsSimulators() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl"], PhoneCommandResult(status: 72, stderr: "unable to find utility"))
        #expect(try await XcodePhoneBackend(runner: runner).devices().count == 5)
    }

    @Test func screenshotUsesSimctlForSimulatorsAndDevicectlForDevices() async throws {
        let runner = FakePhoneRunner()
        let backend = XcodePhoneBackend(runner: runner)
        try await backend.screenshot(sim, to: URL(fileURLWithPath: "/tmp/a.png"))
        try await backend.screenshot(dev, to: URL(fileURLWithPath: "/tmp/b.png"))
        #expect(runner.runs == [
            ["simctl", "io", "SIM-1", "screenshot", "--type=png", "/tmp/a.png"],
            ["devicectl", "device", "capture", "screenshot", "--device", "DEV-1", "--destination", "/tmp/b.png", "--quiet"],
        ])
    }

    @Test func recordingIsH264MovOnSimulatorAndMp4OnDevice() async throws {
        let runner = FakePhoneRunner()
        let backend = XcodePhoneBackend(runner: runner)
        #expect(backend.videoExtension(for: sim) == "mov")
        #expect(backend.videoExtension(for: dev) == "mp4")
        _ = try await backend.startVideo(sim, to: URL(fileURLWithPath: "/tmp/s.mov"))
        _ = try await backend.startVideo(dev, to: URL(fileURLWithPath: "/tmp/d.mp4"))
        #expect(runner.started.map(\.arguments) == [
            ["simctl", "io", "SIM-1", "recordVideo", "--codec=h264", "--force", "/tmp/s.mov"],
            ["devicectl", "device", "capture", "screen-record", "--device", "DEV-1", "--destination", "/tmp/d.mp4", "--codec", "h264", "--quiet"],
        ])
    }

    @Test func bootingABootedSimulatorSucceeds() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "boot"], PhoneCommandResult(status: 149, stderr: "Unable to boot device in current state: Booted"))
        try await XcodePhoneBackend(runner: runner).boot(sim)
    }

    @Test func aFailedCommandCarriesItsStderr() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "io"], PhoneCommandResult(status: 164, stderr: "Invalid device: SIM-1\n"))
        await #expect(throws: PhoneError.commandFailed(command: "simctl screenshot", status: 164, stderr: "Invalid device: SIM-1\n")) {
            try await XcodePhoneBackend(runner: runner).screenshot(sim, to: URL(fileURLWithPath: "/tmp/x.png"))
        }
    }

    @Test func clipboardTextGoesThroughStdinAndURLsOpen() async throws {
        let runner = FakePhoneRunner()
        let backend = XcodePhoneBackend(runner: runner)
        try await backend.send(.pasteboard("hello"), to: sim)
        try await backend.send(.openURL(URL(string: "https://cmux.com")!), to: sim)
        #expect(runner.runs == [["simctl", "pbcopy", "SIM-1"], ["simctl", "openurl", "SIM-1", "https://cmux.com"]])
        #expect(runner.stdins == [Data("hello".utf8)])
    }

    @Test func realDevicesRefuseInputAndBootWithAClearReason() async {
        let backend = XcodePhoneBackend(runner: FakePhoneRunner())
        await #expect(throws: PhoneError.unsupported(mode: .device, what: "tap")) {
            try await backend.send(.tap(PhonePoint(x: 1, y: 2)), to: dev)
        }
        await #expect(throws: PhoneError.unsupported(mode: .device, what: "boot")) { try await backend.boot(dev) }
    }
}
