import Foundation
import Testing
@testable import CmuxNextPhone

@Suite struct PhoneFeedbackClipTests {
    func recording() -> PhoneRecording {
        let device = PhoneDevice(id: PhoneDeviceID(mode: .simulator, raw: "SIM-1"), name: "Test Phone",
                                 model: "iPhone 18 Pro", osVersion: "iOS 27.0", state: .ready)
        var recording = PhoneRecording(id: "rec-1", device: device, startedAt: Date(timeIntervalSince1970: 0),
                                       video: "screen.mov", log: "device-log.ndjson", folder: URL(fileURLWithPath: "/tmp/rec-1"))
        recording.duration = 42.31
        recording.notes = "Checkout spinner never stops."
        recording.events = [PhoneRecordingEvent(at: 1.5, input: .tap(PhonePoint(x: 100.4, y: 200))),
                            PhoneRecordingEvent(at: 3.0, input: .swipe(from: PhonePoint(x: 10, y: 500), to: PhonePoint(x: 10, y: 100), seconds: 0.3)),
                            PhoneRecordingEvent(at: 61.06, input: .text("coupon"))]
        recording.poster = "poster.png"
        return recording
    }

    @Test func theSummaryNamesDeviceLengthNotesStepsAndLogErrors() {
        let log = """
        Filtering the log data using ""
        {"messageType":"Default","eventMessage":"fine","processImagePath":"/usr/libexec/x"}
        {"messageType":"Error","eventMessage":"payment request timed out","processImagePath":"/Applications/Shop.app/Shop"}
        {"messageType":"Fault","eventMessage":"layout loop","processImagePath":"/System/UIKitCore"}
        """
        let clip = PhoneFeedbackClip(recording(), logTail: PhoneLogTail(ndjson: Data(log.utf8)))
        let text = clip.markdown
        #expect(text.contains("Test Phone (iPhone 18 Pro, iOS 27.0) · 0:42.3 · 3 inputs, 1 taps"))
        #expect(text.contains("Checkout spinner never stops."))
        #expect(text.contains("- 0:01.5 tap (100, 200)"))
        #expect(text.contains("- 0:03.0 swipe (10, 500) → (10, 100)"))
        #expect(text.contains("- 1:01.1 text `coupon`"))
        #expect(text.contains("[error] Shop: payment request timed out"))
        #expect(text.contains("[fault] UIKitCore: layout loop"))
        #expect(!text.contains("fine"))
        #expect(clip.attachments.map(\.lastPathComponent) == ["screen.mov", "poster.png"])
    }

    @Test func theLogTailKeepsOnlyTheNewestErrors() {
        let lines = (1...20).map { #"{"messageType":"Error","eventMessage":"e\#($0)","processImagePath":"/p"}"# }
        let tail = PhoneLogTail(ndjson: Data(lines.joined(separator: "\n").utf8), limit: 3)
        #expect(tail.lines.map(\.message) == ["e18", "e19", "e20"])
    }

    @Test func clipboardTextIsNotWrittenIntoTheEventLog() {
        let event = PhoneRecordingEvent(at: 0, input: .pasteboard("secret token"))
        #expect(event.detail == nil)
    }
}
