import Foundation
import Testing
@testable import CmuxNextPhone

@MainActor
@Suite struct PhoneServiceTests {
    final class Inbox: PhoneFeedbackSink {
        var clips: [PhoneFeedbackClip] = []
        func send(_ clip: PhoneFeedbackClip) async throws { clips.append(clip) }
    }

    func service(_ runner: FakePhoneRunner, hid: FakeSimulatorHID? = nil) throws -> PhoneService {
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("devicectl-list")))
        let backend = XcodePhoneBackend(runner: runner, hid: hid)
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

    /// Socket and CLI arguments reach `send`: a point or swipe time no screen has is refused before the recording
    /// logs it, so the feedback summary never sees it (p10-stability-093 fixer; before, `phone feedback` trapped
    /// on a recorded `phone.tap x=1e300`).
    @Test func aPointOrSwipeTimeNoScreenHasIsRefusedBeforeItIsRecorded() async throws {
        let hid = FakeSimulatorHID()
        let phones = try service(FakePhoneRunner(), hid: hid)
        let phone = try await phones.defaultDevice()
        try await phones.startRecording(phone.id)
        await #expect(throws: PhoneError.outsideScreen) { try await phones.send(.tap(PhonePoint(x: 1e300, y: 0)), to: phone.id) }
        await #expect(throws: PhoneError.outsideScreen) { try await phones.send(.tap(PhonePoint(x: .nan, y: 0)), to: phone.id) }
        let start = PhonePoint(x: 10, y: 10), end = PhonePoint(x: 10, y: 100)
        for seconds in [1e300, .infinity, -.infinity, .nan, -1, PhoneInput.longestSwipe + 1] {
            await #expect(throws: PhoneError.outOfRange(what: "the swipe's seconds")) {
                try await phones.send(.swipe(from: start, to: end, seconds: seconds), to: phone.id)
            }
        }
        try await phones.send(.tap(PhonePoint(x: 100, y: 200)), to: phone.id)
        let clip = try await phones.sendFeedback()
        #expect(clip.recording.events.map(\.kind) == ["tap"])
        #expect(hid.sent.count == 1)
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
}
