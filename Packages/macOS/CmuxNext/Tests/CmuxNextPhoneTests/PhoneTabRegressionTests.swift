import AppKit
import Foundation
import Testing
@testable import CmuxNextPhone

/// Bugs found going through the phone tab end to end (u9770): the status line, the Boot
/// button and errors as a person sees them.
@MainActor @Suite struct PhoneTabRegressionTests {
    let booted = PhoneDeviceID(mode: .simulator, raw: "6A05764C-FFD1-4B40-AA2E-AD27ADAC7A56")
    let unavailable = PhoneDeviceID(mode: .simulator, raw: "2F003CA7-8D5F-4B8D-AD72-0666F22137F1")

    func service(listing: Data) -> PhoneService {
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: listing))
        runner.answer(["devicectl"], PhoneCommandResult(status: 1))
        let folder = temporaryFolder()
        return PhoneService(backend: XcodePhoneBackend(runner: runner, hid: FakeSimulatorHID()),
                            recordings: folder.appendingPathComponent("recordings"), scratch: folder)
    }

    @Test func theStatusLineStopsSayingBootingOnceThePhoneRuns() async throws {
        let phones = service(listing: try fixture("simctl-list"))
        try await phones.reload()
        let tab = PhoneTabView(service: phones, device: booted)
        // What the Boot button wrote before the boot finished.
        tab.status.stringValue = PhoneStrings.booting
        tab.syncControls()
        #expect(tab.status.stringValue != PhoneStrings.booting)
    }

    @Test func aSimulatorWhoseIOSIsNotInstalledOffersNoBootButtonButSaysWhy() async throws {
        let phones = service(listing: try fixture("simctl-list"))
        try await phones.reload()
        let tab = PhoneTabView(service: phones, device: unavailable)
        tab.syncControls()
        #expect(tab.bootButton.isHidden, "Boot only fails for a simulator whose runtime is missing")
        #expect(!tab.status.stringValue.isEmpty)
    }

    @Test func toolFailuresShowInPlainWordsNotRawOutput() async throws {
        let phones = service(listing: try fixture("simctl-list"))
        let tab = PhoneTabView(service: phones, device: booted)
        tab.show(PhoneError.commandFailed(command: "simctl boot", status: 149,
                                          stderr: "Unable to boot device because it cannot be located on disk. The device's runtime is unavailable at /Users/me/Library/Developer/CoreSimulator/Devices/X"))
        #expect(!tab.status.stringValue.contains("simctl"))
        #expect(!tab.status.stringValue.contains("/Users/"))
        #expect(!tab.status.stringValue.contains("149"))
    }

    @Test func aMacWithNoPhonesGetsAHintNotAnError() async throws {
        let phones = service(listing: Data(#"{"devices":{}}"#.utf8))
        let tab = PhoneTabView(service: phones, device: nil)
        await tab.start()
        #expect(!tab.status.stringValue.contains("(none)"))
        #expect(tab.status.stringValue == PhoneStrings.noPhones)
    }
}
