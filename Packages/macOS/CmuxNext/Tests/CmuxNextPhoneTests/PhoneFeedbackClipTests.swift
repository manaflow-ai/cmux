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

    @Test func theSummaryNamesDeviceLengthNotesStepsAndLogErrors() throws {
        let log = """
        Filtering the log data using ""
        {"messageType":"Default","eventMessage":"fine","processImagePath":"/usr/libexec/x"}
        {"messageType":"Error","eventMessage":"payment request timed out","processImagePath":"/Applications/Shop.app/Shop"}
        {"messageType":"Fault","eventMessage":"layout loop","processImagePath":"/System/UIKitCore"}
        """
        let clip = try PhoneFeedbackClip(recording(), logTail: PhoneLogTail(ndjson: Data(log.utf8)))
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

    /// manifest.json is a file: a time or point no recording can have is refused when it is read, so the summary's
    /// whole-number conversions never see it (p10-stability-093; before, `clock` trapped on `Int(1e300)`).
    @Test func aManifestWithATimeOrPointNoRecordingHasIsRefused() throws {
        let fine = try JSONDecoder().decode(PhoneRecording.self, from: JSONEncoder().encode(recording()))
        #expect(fine.events.count == 3)
        var lateEvent = recording()
        lateEvent.events = [PhoneRecordingEvent(at: 1e300, input: .text("x"))]
        var farPoint = recording()
        farPoint.events = [PhoneRecordingEvent(at: 1, input: .tap(PhonePoint(x: -1e300, y: 0)))]
        var longRecording = recording()
        longRecording.duration = 1e19
        for hostile in [lateEvent, farPoint, longRecording] {
            let data = try JSONEncoder().encode(hostile)
            #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(PhoneRecording.self, from: data) }
        }
    }

    /// An in-memory recording is not decoded, so the summary itself refuses a time or point no `Int` holds
    /// (p10-stability-093 fixer; before, `clock` and the step points trapped on `Int(1e300)`).
    @Test func aClipOfATimeOrPointNoIntHoldsIsATypedError() {
        var lateEvent = recording()
        lateEvent.events = [PhoneRecordingEvent(at: 1e300, input: .text("x"))]
        var farPoint = recording()
        farPoint.events = [PhoneRecordingEvent(at: 1, input: .tap(PhonePoint(x: 1e300, y: 0)))]
        var endlessSwipe = recording()
        endlessSwipe.events = [PhoneRecordingEvent(at: 1, input: .swipe(from: PhonePoint(x: 0, y: 0),
                                                                     to: PhonePoint(x: .infinity, y: 0), seconds: 0.3))]
        var unknownLength = recording()
        unknownLength.duration = .nan
        for hostile in [lateEvent, farPoint, endlessSwipe, unknownLength] {
            #expect(throws: PhoneError.self) { _ = try PhoneFeedbackClip(hostile) }
        }
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
