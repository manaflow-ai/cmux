import Foundation
import Testing
@testable import CmuxNextPhone

/// The Android backend (plans/cmux-next/simulators-DESIGN.md): emulators and
/// USB devices through the SDK's own `adb` and `emulator`, so cmux bundles
/// nothing. Every test runs against a fake runner and a fake SDK root.
@Suite struct AndroidPhoneBackendTests {
    let sdk = AndroidSDK(root: URL(fileURLWithPath: "/sdk"))
    var adb: String { "/sdk/platform-tools/adb" }
    var emulator: String { "/sdk/emulator/emulator" }

    /// A runner that knows one running emulator (Pixel_8_API_35 on 5554),
    /// one shut-down AVD and one USB phone.
    func runner() -> FakePhoneRunner {
        let runner = FakePhoneRunner()
        runner.answer([emulator, "-list-avds"], PhoneCommandResult(status: 0, stdout: Data("Pixel_8_API_35\nTablet_API_34\n".utf8)))
        runner.answer([adb, "devices", "-l"], PhoneCommandResult(status: 0, stdout: Data("""
            List of devices attached
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
            R58M123                device usb:1-1 product:panther model:Pixel_7 device:panther transport_id:2

            """.utf8)))
        runner.answer([adb, "-s", "emulator-5554", "emu", "avd", "name"], PhoneCommandResult(status: 0, stdout: Data("Pixel_8_API_35\r\nOK\r\n".utf8)))
        runner.answer([adb, "-s", "emulator-5554", "shell", "getprop", "ro.build.version.release"], PhoneCommandResult(status: 0, stdout: Data("15\n".utf8)))
        runner.answer([adb, "-s", "R58M123", "shell", "getprop", "ro.build.version.release"], PhoneCommandResult(status: 0, stdout: Data("14\n".utf8)))
        runner.answer([adb, "-s", "emulator-5554", "shell", "wm", "density"], PhoneCommandResult(status: 0, stdout: Data("Physical density: 420\n".utf8)))
        return runner
    }

    let pixel = PhoneDeviceID(mode: .emulator, raw: "Pixel_8_API_35")
    let tablet = PhoneDeviceID(mode: .emulator, raw: "Tablet_API_34")

    @Test func listsAVDsAndUSBDevicesWithRunningOnesReady() async throws {
        let phones = try await AndroidPhoneBackend(sdk: sdk, runner: runner()).devices()
        #expect(phones.map(\.id.description) == ["avd:Pixel_8_API_35", "adb:R58M123", "avd:Tablet_API_34"])
        #expect(phones[0].state == .ready)
        #expect(phones[0].name == "Pixel 8 API 35")
        #expect(phones[0].osVersion == "Android 15")
        #expect(phones[1].model == "Pixel 7")
        #expect(phones[1].osVersion == "Android 14")
        #expect(phones[2].state == .shutdown)
    }

    @Test func tapsAreSentInPixelsFromDensityIndependentPoints() async throws {
        let runner = runner()
        let backend = AndroidPhoneBackend(sdk: sdk, runner: runner)
        try await backend.send(.tap(PhonePoint(x: 100, y: 200)), to: pixel)
        try await backend.send(.swipe(from: PhonePoint(x: 10, y: 400), to: PhonePoint(x: 10, y: 40), seconds: 0.3), to: pixel)
        #expect(runner.runs.contains([adb, "-s", "emulator-5554", "shell", "input", "tap", "263", "525"]))
        #expect(runner.runs.contains([adb, "-s", "emulator-5554", "shell", "input", "swipe", "26", "1050", "26", "105", "300"]))
    }

    /// `adb input` takes whole pixels and milliseconds: a point or swipe time no `Int` holds is a typed error before
    /// any adb input run (p10-stability-093 fixer; before, `px` and the swipe's milliseconds trapped on 1e300 and inf).
    @Test func aPointOrSwipeTimeNoScreenHasIsRefusedBeforeAdbRuns() async throws {
        let runner = runner()
        let backend = AndroidPhoneBackend(sdk: sdk, runner: runner)
        await #expect(throws: PhoneError.outsideScreen) { try await backend.send(.tap(PhonePoint(x: 1e300, y: 0)), to: pixel) }
        await #expect(throws: PhoneError.outsideScreen) { try await backend.send(.tap(PhonePoint(x: .infinity, y: 0)), to: pixel) }
        let start = PhonePoint(x: 10, y: 400), end = PhonePoint(x: 10, y: 40)
        for seconds in [1e300, .infinity, .nan, -1] {
            await #expect(throws: PhoneError.outOfRange(what: "the swipe's seconds")) {
                try await backend.send(.swipe(from: start, to: end, seconds: seconds), to: pixel)
            }
        }
        #expect(!runner.runs.contains { $0.contains("input") })
    }

    @Test func typedTextIsQuotedForTheDeviceShell() async throws {
        let runner = runner()
        try await AndroidPhoneBackend(sdk: sdk, runner: runner).send(.text("it's a & b"), to: pixel)
        #expect(runner.runs.last == [adb, "-s", "emulator-5554", "shell", "input text 'it'\\''s%sa%s&%sb'"])
    }

    @Test func buttonsAreKeyEvents() async throws {
        let runner = runner()
        let backend = AndroidPhoneBackend(sdk: sdk, runner: runner)
        for button in [PhoneButton.home, .back, .lock, .volumeUp, .appSwitch] { try await backend.send(.button(button), to: pixel) }
        let keys = runner.runs.filter { $0.contains("keyevent") }.map { $0.last ?? "" }
        #expect(keys == ["KEYCODE_HOME", "KEYCODE_BACK", "KEYCODE_POWER", "KEYCODE_VOLUME_UP", "KEYCODE_APP_SWITCH"])
    }

    @Test func deepLinksDarkModeAndLocation() async throws {
        let runner = runner()
        let backend = AndroidPhoneBackend(sdk: sdk, runner: runner)
        try await backend.send(.openURL(URL(string: "myapp://item?a=1&b=2")!), to: pixel)
        try await backend.send(.appearance(.dark), to: pixel)
        try await backend.send(.location(latitude: 37.33, longitude: -122.03), to: pixel)
        let runs = runner.runs.suffix(3)
        #expect(Array(runs) == [
            [adb, "-s", "emulator-5554", "shell", "am start -a android.intent.action.VIEW -d 'myapp://item?a=1&b=2'"],
            [adb, "-s", "emulator-5554", "shell", "cmd", "uimode", "night", "yes"],
            // The console's geo fix takes the longitude first.
            [adb, "-s", "emulator-5554", "emu", "geo", "fix", "-122.03", "37.33"],
        ])
    }

    @Test func installAndLaunchAnApp() async throws {
        let runner = runner()
        let backend = AndroidPhoneBackend(sdk: sdk, runner: runner)
        try await backend.send(.install(URL(fileURLWithPath: "/tmp/app.apk")), to: pixel)
        try await backend.send(.launch("com.example.app"), to: pixel)
        #expect(Array(runner.runs.suffix(2)) == [
            [adb, "-s", "emulator-5554", "install", "-r", "/tmp/app.apk"],
            [adb, "-s", "emulator-5554", "shell", "monkey", "-p", "com.example.app", "-c", "android.intent.category.LAUNCHER", "1"],
        ])
    }

    @Test func screenshotWritesScreencapOutput() async throws {
        let runner = runner()
        runner.answer([adb, "-s", "emulator-5554", "exec-out", "screencap", "-p"], PhoneCommandResult(status: 0, stdout: Data("PNGDATA".utf8)))
        let file = temporaryFolder().appendingPathComponent("a.png")
        try await AndroidPhoneBackend(sdk: sdk, runner: runner).screenshot(pixel, to: file)
        #expect(try Data(contentsOf: file) == Data("PNGDATA".utf8))
    }

    @Test func bootStartsAHeadlessEmulatorOnTheNextFreePortAndWaitsForBoot() async throws {
        let runner = runner()
        try await AndroidPhoneBackend(sdk: sdk, runner: runner).boot(tablet)
        // 5554 is taken by the running Pixel, so the tablet gets 5556.
        #expect(runner.started.map(\.arguments) == [
            [emulator, "-avd", "Tablet_API_34", "-port", "5556", "-no-window", "-no-audio", "-no-boot-anim"],
        ])
        #expect(runner.runs.contains([adb, "-s", "emulator-5556", "wait-for-device", "shell",
                                      "while [ \"$(getprop sys.boot_completed)\" != 1 ]; do sleep 1; done"]))
    }

    @Test func shutdownKillsTheEmulatorThroughItsConsole() async throws {
        let runner = runner()
        try await AndroidPhoneBackend(sdk: sdk, runner: runner).shutdown(pixel)
        #expect(runner.runs.last == [adb, "-s", "emulator-5554", "emu", "kill"])
    }

    @Test func aShutDownAVDRefusesInputWithAClearReason() async {
        let backend = AndroidPhoneBackend(sdk: sdk, runner: runner())
        await #expect(throws: PhoneError.notRunning("avd:Tablet_API_34")) {
            try await backend.send(.tap(PhonePoint(x: 1, y: 1)), to: tablet)
        }
    }

    @Test func accessibilityTreeComesFromUIAutomator() async throws {
        let runner = runner()
        runner.answer([adb, "-s", "emulator-5554", "exec-out", "uiautomator", "dump", "/dev/tty"], PhoneCommandResult(status: 0, stdout: Data("""
            <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]"><node index="0" text="Sign in" resource-id="com.example:id/login" class="android.widget.Button" content-desc="" clickable="true" bounds="[105,525][420,630]" /></node></hierarchy>UI hierchary dumped to: /dev/tty
            """.utf8)))
        let tree = try await AndroidPhoneBackend(sdk: sdk, runner: runner).accessibilityTree(pixel)
        let button = try #require(tree.flattened.first { $0.label == "Sign in" })
        #expect(button.role == "Button")
        #expect(button.identifier == "com.example:id/login")
        // Frames are in points (420 dpi: 2.625 px per point), like taps.
        #expect(button.frame == PhoneRect(x: 40, y: 200, width: 120, height: 40))
    }

    @Test func theSDKIsFoundFromTheEnvironmentOrTheDefaultFolder() {
        let home = URL(fileURLWithPath: "/Users/me")
        let fromEnv = AndroidSDK.locate(environment: ["ANDROID_HOME": "/opt/android"], home: home,
                                        fileExists: { $0 == "/opt/android/platform-tools/adb" })
        #expect(fromEnv?.root.path == "/opt/android")
        let fromDefault = AndroidSDK.locate(environment: [:], home: home,
                                            fileExists: { $0 == "/Users/me/Library/Android/sdk/platform-tools/adb" })
        #expect(fromDefault?.root.path == "/Users/me/Library/Android/sdk")
        #expect(AndroidSDK.locate(environment: [:], home: home, fileExists: { _ in false }) == nil)
    }
}
