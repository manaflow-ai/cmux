@testable import CmuxNextAgentPane
import Foundation
import Testing

/// What `composer.capture` answers the page for what `screencapture` wrote: a capture named for
/// when it was taken (so two in one prompt differ), nothing for a cancelled pick, and a capture of
/// any size as the bytes `screencapture` wrote.
struct AgentPaneCaptureTests {
    private static let taken = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                              year: 2026, month: 10, day: 11, hour: 14, minute: 32, second: 5).date!

    @Test func aCaptureIsNamedForWhenItWasTaken() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let answer = AgentPaneCapture.answer(png, taken: Self.taken)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["mimeType"] as? String == "image/png")
        #expect(answer["data"] as? String == png.base64EncodedString())
    }

    @Test func aCancelledPickAnswersNothingToAttach() {
        let answer = AgentPaneCapture.answer(Data(), taken: Self.taken)
        #expect(answer["cancelled"] as? Bool == true)
        #expect(answer["data"] == nil)
    }

    @Test func aLargeCaptureAttachesAsItWasTakenNeverShrunkOrRefused() {
        // Leo, 2026-10-26: "WE NEED ARBITARRILY LARGE FILES OF ANY TYPE". A 6 MiB capture is the
        // person's original: the page makes its own preview for the model and saves the original.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(count: 6 * 1024 * 1024))
        let answer = AgentPaneCapture.answer(png, taken: Self.taken)
        #expect(answer["tooLarge"] == nil)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["mimeType"] as? String == "image/png")
        #expect(answer["data"] as? String == png.base64EncodedString())
    }
}
