import Foundation
import Testing
@testable import CmuxNextPhone

/// The iOS simulator setup steps a Mac needs, and the two cmux runs itself (u9770).
@Suite struct PhoneSetupCheckTests {
    static let xcode = "/Applications/Xcode.app/Contents/Developer"
    let installed = XcodeLocator(environment: [:], selectedLink: { nil }, fileExists: { $0 == PhoneSetupCheckTests.xcode + "/usr/bin/simctl" },
                                 applications: { ["/Applications/Xcode.app"] })

    @Test func noXcodeMeansInstallXcodeAndNothingRuns() async {
        let runner = FakePhoneRunner()
        let none = XcodeLocator(environment: [:], selectedLink: { nil }, fileExists: { _ in false }, applications: { [] })
        let status = await PhoneSetupCheck(xcode: none, runner: runner).status()
        #expect(status.step == .installXcode)
        #expect(runner.runs.isEmpty, "xcrun on a Mac without tools pops up the command line tools installer")
    }

    @Test func anXcodeThatWasNeverOpenedNeedsOpeningOnce() async {
        let runner = FakePhoneRunner()
        runner.answer(["simctl"], PhoneCommandResult(status: 69, stderr: "You have not agreed to the Xcode license agreements."))
        let status = await PhoneSetupCheck(xcode: installed, runner: runner).status()
        #expect(status.step == .finishXcode)
        #expect(status.xcodeApp == "/Applications/Xcode.app")
    }

    @Test func xcodeWithoutAnIOSRuntimeNeedsTheDownload() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list", "runtimes"], PhoneCommandResult(status: 0, stdout: Data(#"{"runtimes":[]}"#.utf8)))
        #expect(await PhoneSetupCheck(xcode: installed, runner: runner).status().step == .downloadIOS)
    }

    @Test func aRuntimeWithoutAUsableSimulatorNeedsAnIPhone() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list", "runtimes"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-runtimes")))
        runner.answer(["simctl", "list", "devices"], PhoneCommandResult(status: 0, stdout: Data(#"{"devices":{}}"#.utf8)))
        let status = await PhoneSetupCheck(xcode: installed, runner: runner).status()
        #expect(status.step == .createIPhone)
        #expect(status.runtime?.name == "iOS 27.0")
        #expect(status.runtime?.suggestedIPhone?.name == "iPhone 18")
    }

    @Test func aMacWithASimulatorIsReady() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list", "runtimes"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-runtimes")))
        runner.answer(["simctl", "list", "devices"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        #expect(await PhoneSetupCheck(xcode: installed, runner: runner).status().step == .ready)
    }

    @Test func createMakesTheSuggestedIPhoneOnTheNewestRuntime() async throws {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list", "runtimes"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-runtimes")))
        runner.answer(["simctl", "create"], PhoneCommandResult(status: 0, stdout: Data("NEW-UDID\n".utf8)))
        let made = try await PhoneSetupCheck(xcode: installed, runner: runner).createIPhone()
        #expect(made == PhoneDeviceID(mode: .simulator, raw: "NEW-UDID"))
        #expect(runner.runs.last == ["simctl", "create", "iPhone 18", "com.apple.CoreSimulator.SimDeviceType.iPhone-18",
                                     "com.apple.CoreSimulator.SimRuntime.iOS-27-0"])
    }

    @Test @MainActor func theDownloadReportsProgressAndAFailureInPlainWords() async throws {
        let runner = FakePhoneRunner()
        runner.stream(["xcodebuild", "-downloadPlatform", "iOS"], [
            .output("Downloading iOS 27.0 Simulator (24A1): 12.5% (1.05 GB of 8.40 GB)\r"),
            .output("Downloading iOS 27.0 Simulator (24A1): 50.0% (4.20 GB of 8.40 GB)\n"),
            .exited(70, stderr: "Error: No space left on device"),
        ])
        let seen = ProgressLog()
        let check = PhoneSetupCheck(xcode: installed, runner: runner)
        do {
            try await check.downloadIOS { seen.items.append($0) }
            Issue.record("a failed download must throw")
        } catch {
            #expect(PhoneErrorText(error).message == PhoneStrings.errorDiskFull)
        }
        #expect(seen.items.map(\.fraction) == [0.125, 0.5])
        #expect(seen.items.last?.amount == "4.20 GB of 8.40 GB")
    }

    @Test func runtimesAreIOSOnlyAvailableAndNewestFirst() throws {
        let runtimes = try SimctlRuntimeList().parse(try fixture("simctl-runtimes"))
        #expect(runtimes.map(\.name) == ["iOS 27.0", "iOS 18.0"])
        #expect(runtimes.last?.iPhoneTypes.map(\.name) == ["iPhone 16"])
    }
}

@MainActor final class ProgressLog {
    var items: [PhoneSetupProgress] = []
}
