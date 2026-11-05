@testable import CmuxVNCWebRTC
import CoreGraphics
import Foundation
import Testing

/// Telepointers (Petal's cursors as metadata): a viewer that draws pointers
/// says so, the host leaves the cursor out of the picture and sends where
/// the person's and the agent's pointers are, as fractions of the display.
struct TelepointerTests {
    @Test func aViewerSaysItDrawsPointers() {
        #expect(ScreenStreamHost.viewerDrawsPointers(ScreenInput(t: "caps", s: "telepointers")))
        #expect(ScreenStreamHost.viewerDrawsPointers(ScreenInput(t: "caps", s: "scroll-px, telepointers")))
        #expect(!ScreenStreamHost.viewerDrawsPointers(ScreenInput(t: "caps", s: "scroll-px")))
        #expect(!ScreenStreamHost.viewerDrawsPointers(ScreenInput(t: "caps")))
        #expect(!ScreenStreamHost.viewerDrawsPointers(ScreenInput(t: "text", s: "telepointers")), "only a caps message")
    }

    @Test func pointersAreFractionsOfTheStreamedDisplay() {
        // A second display to the right of a 1728-point-wide main display.
        let display = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        #expect(ScreenStreamHost.fraction(of: CGPoint(x: 1728 + 960, y: 270), in: display) == .init(x: 0.5, y: 0.25))
        #expect(ScreenStreamHost.fraction(of: CGPoint(x: 100, y: 100), in: display) == nil, "on another display")
        #expect(ScreenStreamHost.fraction(of: nil, in: display) == nil, "no pointer")
        #expect(ScreenStreamHost.fraction(of: CGPoint(x: 1800, y: 10), in: nil) == nil, "no display")
    }

    @Test func theMessageCarriesBothPointersAndAnOldViewerIgnoresIt() throws {
        var message = ScreenHostMessage(t: ScreenHostMessage.telepointersType)
        message.person = .init(x: 0.25, y: 0.5)
        let data = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["t"] as? String == "telepointers")
        #expect(object["agent"] == nil, "a pointer off the display is absent")
        let decoded = try JSONDecoder().decode(ScreenHostMessage.self, from: data)
        #expect(decoded.person == .init(x: 0.25, y: 0.5) && decoded.agent == nil)
        // A viewer reads only `displays` and `caps`: telepointers are neither.
        #expect(!ScreenStreamViewer.isDisplays(decoded))
        #expect(ScreenStreamViewer.capabilities(in: decoded) == nil)
    }

    /// The viewer's capability report is a `caps` input carrying `telepointers`.
    @Test func theViewerReportIsACapsInput() throws {
        let input = ScreenInput(t: ScreenHostMessage.capabilitiesType, s: ScreenHostMessage.telepointersCapability)
        let decoded = try JSONDecoder().decode(ScreenInput.self, from: JSONEncoder().encode(input))
        #expect(ScreenStreamHost.viewerDrawsPointers(decoded))
    }
}
