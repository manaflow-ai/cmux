import CmuxScreenKit
import CoreGraphics
import Foundation
import Testing

struct ScreenInputTests {
    // MARK: Preferences

    @Test func inputModeDefaultsToDirectForOlderPreferences() throws {
        let old = try JSONDecoder().decode(ScreenPreferences.self,
                                           from: Data(#"{"localCursor":true,"showStats":false,"fitToDisplay":true,"quality":"medium"}"#.utf8))
        #expect(old.inputMode == .direct)
        #expect(old.quality == .medium && !old.showStats, "the other keys still load")
        let unknown = try JSONDecoder().decode(ScreenPreferences.self, from: Data(#"{"inputMode":"stylus"}"#.utf8))
        #expect(unknown.inputMode == .direct)
        #expect(ScreenPreferences().inputMode == .direct)
    }

    @Test func inputModeRoundTrips() throws {
        let preferences = ScreenPreferences(inputMode: .trackpad)
        let data = try JSONEncoder().encode(preferences)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["inputMode"] as? String == "trackpad")
        #expect(try JSONDecoder().decode(ScreenPreferences.self, from: data) == preferences)
        #expect(ScreenInputMode.allCases.map(\.title) == ["Direct Touch", "Trackpad"])
        #expect(ScreenInputMode.allCases.allSatisfy { !$0.symbol.isEmpty })
    }

    // MARK: Host capabilities and scrolling

    @Test func capsMessageCarriesTheHostsCapabilities() throws {
        let caps = try JSONDecoder().decode(ScreenHostMessage.self, from: Data(#"{"t":"caps","s":"scroll-px,mods"}"#.utf8))
        #expect(caps.t == ScreenHostMessage.capabilitiesType && caps.s == "scroll-px,mods")
        #expect(ScreenHostMessage.pixelScrollCapability == "scroll-px" && ScreenInput.pixelUnit == "px")
    }

    @Test func pixelScrollCarriesItsUnitAndLineScrollDoesNot() throws {
        let pixels = try object(ScreenSession.scrollInput(x: 0.5, y: 0.25, dx: -3, dy: 42, pixels: true))
        #expect(pixels["t"] as? String == "scroll" && pixels["u"] as? String == "px")
        #expect(pixels["dx"] as? Int == -3 && pixels["dy"] as? Int == 42 && pixels["x"] as? Double == 0.5)
        // Lines: exactly the message an older host reads (no `u` key at all).
        let lines = try object(ScreenSession.scrollInput(x: 0.5, y: 0.25, dx: 0, dy: 2, pixels: false))
        #expect(lines["u"] == nil)
        #expect(Set(lines.keys) == ["t", "x", "y", "dx", "dy"])
        // An older host decodes a pixel scroll's fields as before.
        let decoded = try JSONDecoder().decode(ScreenInput.self, from: JSONEncoder().encode(ScreenInput(t: "scroll", dx: 1, dy: 2, u: "px")))
        #expect(decoded.u == "px" && decoded.dy == 2)
    }

    /// A session to an older host (no caps) or RFB never sends pixel scrolls;
    /// a host's `caps` turns them on.
    @MainActor @Test func pixelScrollNeedsTheHostsCapability() throws {
        let stream = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac", kind: "stream").link))
        let session = ScreenSession(title: "Mac", pairing: stream)
        #expect(session.hostCapabilities.isEmpty)
        #expect(!session.supportsPixelScroll)
        session.scrollPixels(dx: 10, dy: 10) // not connected, no caps: nothing to send, no crash
        session.receiveCapabilities(["mods"])
        #expect(!session.supportsPixelScroll)
        session.receiveCapabilities(["scroll-px", "mods"])
        #expect(session.supportsPixelScroll && session.hostCapabilities == ["scroll-px", "mods"])
    }

    private func object(_ input: ScreenInput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
    }

    // MARK: Trackpad gesture

    @Test func aTapPressesAtOnceAndReleasesAfterTheDragWindow() {
        var gesture = TrackpadGesture()
        #expect(gesture.touchDown(at: 10).isEmpty)
        #expect(gesture.touchUp(at: 10.1) == [.press])
        #expect(gesture.buttonHeld)
        #expect(gesture.deadline == 10.1 + gesture.dragWindow)
        #expect(gesture.advance(to: 10.2).isEmpty, "still inside the window")
        #expect(gesture.advance(to: 10.4) == [.release])
        #expect(!gesture.buttonHeld && gesture.deadline == nil)
    }

    @Test func aDoubleTapIsTwoClicks() {
        var gesture = TrackpadGesture()
        _ = gesture.touchDown(at: 0)
        #expect(gesture.touchUp(at: 0.08) == [.press])
        #expect(gesture.touchDown(at: 0.2).isEmpty, "the press carries on into the second touch")
        // The first click ends and a second one follows: the Mac counts a double click.
        #expect(gesture.touchUp(at: 0.28) == [.release, .press, .release])
        #expect(!gesture.buttonHeld)
    }

    @Test func tapAndAHalfDragsWithTheTapsPress() {
        var gesture = TrackpadGesture()
        _ = gesture.touchDown(at: 0)
        _ = gesture.touchUp(at: 0.1)
        _ = gesture.touchDown(at: 0.25)
        #expect(gesture.deadline == nil, "no long press or window while dragging")
        #expect(gesture.touchMoved(dx: 4, dy: 0, at: 0.27).isEmpty, "inside the slop")
        #expect(gesture.touchMoved(dx: 6, dy: 0, at: 0.3) == [.move(dx: 10, dy: 0, dt: 0.3 - 0.25)])
        #expect(gesture.touchMoved(dx: 5, dy: 5, at: 0.32) == [.move(dx: 5, dy: 5, dt: 0.32 - 0.3)])
        #expect(gesture.buttonHeld)
        #expect(gesture.touchUp(at: 0.6) == [.release])
    }

    @Test func aStillTouchBecomesALongPressDrag() {
        var gesture = TrackpadGesture()
        _ = gesture.touchDown(at: 1)
        #expect(gesture.deadline == 1 + gesture.longPressDuration)
        #expect(gesture.advance(to: 1.2).isEmpty)
        #expect(gesture.advance(to: 1.5) == [.press])
        #expect(gesture.buttonHeld)
        #expect(gesture.touchMoved(dx: 20, dy: 0, at: 1.6).count == 1)
        #expect(gesture.touchUp(at: 2) == [.release])
    }

    @Test func movingMovesWithoutClicking() {
        var gesture = TrackpadGesture()
        _ = gesture.touchDown(at: 0)
        #expect(gesture.touchMoved(dx: 30, dy: 40, at: 0.05) == [.move(dx: 30, dy: 40, dt: 0.05)])
        #expect(gesture.deadline == nil, "a moving touch never long-presses")
        #expect(gesture.advance(to: 5).isEmpty)
        #expect(gesture.touchUp(at: 0.1).isEmpty)
        // A slow still touch past the tap time that the timer missed clicks nothing either.
        _ = gesture.touchDown(at: 10)
        #expect(gesture.touchUp(at: 10.4).isEmpty)
    }

    @Test func aSecondFingerReleasesAHeldButton() {
        var gesture = TrackpadGesture()
        _ = gesture.touchDown(at: 0)
        _ = gesture.touchUp(at: 0.1)
        #expect(gesture.cancel() == [.release])
        _ = gesture.touchDown(at: 1)
        #expect(gesture.cancel().isEmpty, "nothing was pressed")
    }

    @Test func aLateTouchAfterTheWindowStartsAfresh() {
        var gesture = TrackpadGesture()
        _ = gesture.touchDown(at: 0)
        _ = gesture.touchUp(at: 0.1)
        // The timer has not fired yet, but the window is over: release first, then a new touch.
        #expect(gesture.touchDown(at: 0.9) == [.release])
        #expect(gesture.touchUp(at: 0.95) == [.press])
    }

    // MARK: Pointer math

    @Test func accelerationIsPreciseWhenSlowAndFasterWhenFast() {
        let acceleration = PointerAcceleration()
        #expect(acceleration.gain(speed: 0) == 1)
        #expect(acceleration.gain(speed: 100) == 1)
        #expect(acceleration.gain(speed: 10000) == 3)
        let mid = acceleration.gain(speed: 700)
        #expect(mid > 1 && mid < 3)
        #expect(acceleration.gain(speed: 500) < acceleration.gain(speed: 900), "monotonic")
        // Slow: one point of finger is one point of the view (here 4 framebuffer pixels).
        let slow = acceleration.delta(dx: 1, dy: 0, dt: 0.1, pixelsPerPoint: 4)
        #expect(slow.dx == 4 && slow.dy == 0)
        // Fast: the same direction, three times further.
        let fast = acceleration.delta(dx: 30, dy: 40, dt: 0.01, pixelsPerPoint: 2)
        #expect(abs(fast.dx - 180) < 0.001 && abs(fast.dy - 240) < 0.001)
    }

    @Test func aDoubleTapClicksTwiceAtOnePoint() {
        var snap = ClickSnap()
        let first = snap.point(for: CGPoint(x: 100, y: 100), at: 0, radius: 20)
        #expect(first == CGPoint(x: 100, y: 100))
        #expect(snap.point(for: CGPoint(x: 108, y: 95), at: 0.3, radius: 20) == first, "a wobble stays on the first point")
        #expect(snap.point(for: CGPoint(x: 140, y: 100), at: 0.5, radius: 20) == CGPoint(x: 140, y: 100), "too far: a new point")
        #expect(snap.point(for: CGPoint(x: 141, y: 100), at: 1.5, radius: 20) == CGPoint(x: 141, y: 100), "too late: a new point")
    }
}
