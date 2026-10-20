import Foundation
import Testing
@testable import CmuxNextPhone

@MainActor
@Suite struct PhoneServiceTests {
    final class Inbox: PhoneFeedbackSink {
        var clips: [PhoneFeedbackClip] = []
        func send(_ clip: PhoneFeedbackClip) async throws { clips.append(clip) }
    }

    func service(_ runner: FakePhoneRunner) throws -> PhoneService {
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("devicectl-list")))
        let backend = XcodePhoneBackend(runner: runner)
        return PhoneService(backend: backend, recorder: PhoneRecorder(backend: backend, root: temporaryFolder(), makeID: { "rec" }),
                            scratch: temporaryFolder())
    }

    @Test func theDefaultPhoneIsTheReadySimulator() async throws {
        let phone = try await service(FakePhoneRunner()).defaultDevice()
        #expect(phone.name == "iPhone 18 Pro")
    }

    @Test func inputDuringARecordingIsLoggedThenSentAsFeedback() async throws {
        let runner = FakePhoneRunner()
        let phones = try service(runner)
        let inbox = Inbox()
        phones.feedbackSink = inbox
        let phone = try await phones.defaultDevice()
        try await phones.startRecording(phone.id)
        #expect(phones.recording != nil)
        try await phones.send(.openURL(URL(string: "myapp://cart")!), to: phone.id)
        let clip = try await phones.sendFeedback(notes: "cart is empty")
        #expect(phones.recording == nil)
        #expect(clip.recording.events.map(\.detail) == ["myapp://cart"])
        #expect(clip.recording.notes == "cart is empty")
        #expect(inbox.clips == [clip])
    }

    @Test func inputTheDeviceCannotTakeFailsBeforeAnyCommandRuns() async throws {
        let runner = FakePhoneRunner()
        let phones = try service(runner)
        let real = PhoneDeviceID(mode: .device, raw: "00008140-0000000000000001")
        await #expect(throws: PhoneError.unsupported(mode: .device, what: "open-url")) {
            try await phones.send(.openURL(URL(string: "https://cmux.com")!), to: real)
        }
        #expect(!runner.runs.contains { $0.contains("openurl") })
    }

    @Test func everyChangeBumpsTheChangeCountSoTabsRefreshOnEvents() async throws {
        let phones = try service(FakePhoneRunner())
        let phone = try await phones.defaultDevice()
        let before = phones.changeCount
        try await phones.send(.pasteboard("x"), to: phone.id)
        try await phones.boot(phone.id)
        #expect(phones.changeCount == before + 2)
    }

    @Test func framesAreOneFilePerDevice() async throws {
        let phones = try service(FakePhoneRunner())
        let phone = try await phones.defaultDevice()
        let first = try await phones.frame(phone.id)
        let second = try await phones.frame(phone.id)
        #expect(first == second)
        #expect(first.lastPathComponent == "frame-sim-6A05764C-FFD1-4B40-AA2E-AD27ADAC7A56.png")
    }

    @Test func anExplicitScreenshotPathNeverReplacesAnExistingFile() async throws {
        let phones = try service(FakePhoneRunner())
        let phone = try await phones.defaultDevice()
        let file = temporaryFolder().appendingPathComponent("keep.txt")
        let original = Data("keep me".utf8)
        try original.write(to: file)

        await #expect(throws: (any Error).self) {
            _ = try await phones.screenshot(phone.id, to: file)
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func anExplicitScreenshotPathDoesNotCreateParentFolders() async throws {
        let phones = try service(FakePhoneRunner())
        let phone = try await phones.defaultDevice()
        let parent = temporaryFolder().appendingPathComponent("missing/parents", isDirectory: true)
        let file = parent.appendingPathComponent("phone.png")

        await #expect(throws: (any Error).self) {
            _ = try await phones.screenshot(phone.id, to: file)
        }
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }

    @Test func aNewExplicitScreenshotIsPrivate() async throws {
        let phones = try service(FakePhoneRunner())
        let phone = try await phones.defaultDevice()
        let file = temporaryFolder().appendingPathComponent("phone.png")

        _ = try await phones.screenshot(phone.id, to: file)

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
}
