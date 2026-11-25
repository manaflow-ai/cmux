#if os(iOS)
import CmuxScreenKit
import Foundation
import QuartzCore
import Testing
@testable import CmuxMobileScreenSharing

/// Follow mode over the shared follow camera: the Mac's `focus` events in,
/// the crop (a fraction of the display) out, on the phone's clock.
@MainActor @Suite struct ScreenSharingFollowCameraTests {
    /// A portrait iPhone's view (393x852 points).
    let portrait: CGFloat = 393.0 / 852
    /// The phone's clock, which the tests move.
    final class Clock { var time: CFTimeInterval = 100 }

    func camera(_ clock: Clock, reduceMotion: Bool = false) -> ScreenSharingFollowCamera {
        ScreenSharingFollowCamera(reduceMotion: { reduceMotion }, now: { clock.time })
    }

    func send(_ camera: ScreenSharingFollowCamera, _ json: String) {
        camera.receive(Data(json.utf8))
    }

    /// Frames at 60 Hz for `seconds`; the last crop.
    func run(_ camera: ScreenSharingFollowCamera, _ clock: Clock, seconds: Double) -> CGRect? {
        var crop: CGRect?
        for _ in 0 ..< Int(seconds * 60) {
            clock.time += 1.0 / 60
            crop = camera.crop(at: clock.time, aspect: portrait)
        }
        return crop
    }

    @Test func availableOnceTheMacSaysItsDisplay() {
        let clock = Clock(), camera = camera(clock)
        #expect(!camera.isAvailable)
        send(camera, #"{"t_us":5,"kind":"pointer","x":10,"y":10}"#)
        #expect(!camera.isAvailable, "an older Mac sends no source")
        send(camera, #"{"t_us":5,"kind":"source","w":1920,"h":1080}"#)
        #expect(camera.isAvailable)
        #expect(camera.crop(at: clock.time, aspect: portrait) == nil, "Follow is off")
    }

    /// The first crop: half the display wide at its full height (readable
    /// terminal lines, shown letterboxed), centred.
    @Test func startsReadableAndCentred() throws {
        let clock = Clock(), camera = camera(clock)
        send(camera, #"{"t_us":5,"kind":"source","w":1920,"h":1080}"#)
        camera.toggle()
        let crop = try #require(camera.crop(at: clock.time, aspect: portrait))
        #expect(abs(crop.width - 0.5) < 1e-9 && abs(crop.height - 1) < 1e-9, "\(crop)")
        #expect(abs(crop.minX - 0.25) < 1e-9 && crop.minY == 0, "\(crop)")
    }

    /// Typing at the end of a long line on the right: the crop pans there
    /// and keeps the caret in view; the Mac's clock never matters.
    @Test func followsTheCaret() throws {
        let clock = Clock(), camera = camera(clock)
        send(camera, #"{"t_us":999000000000,"kind":"source","w":1920,"h":1080}"#)
        send(camera, #"{"t_us":999000000000,"kind":"window","id":3,"x":0,"y":0,"w":1920,"h":1080}"#)
        camera.toggle()
        _ = run(camera, clock, seconds: 0.5)
        send(camera, #"{"t_us":999000500000,"kind":"caret","x":1800,"y":700,"w":2,"h":20}"#)
        let crop = try #require(run(camera, clock, seconds: 2))
        #expect(crop.minX <= 1800.0 / 1920 && 1800.0 / 1920 <= crop.maxX, "caret in view: \(crop)")
        #expect(crop.minX > 0.25, "panned right: \(crop)")
    }

    /// An app switch is a cut: the next frame is on the new window.
    @Test func aWindowSwitchCuts() throws {
        let clock = Clock(), camera = camera(clock)
        send(camera, #"{"t_us":0,"kind":"source","w":1920,"h":1080}"#)
        send(camera, #"{"t_us":0,"kind":"window","id":1,"x":0,"y":0,"w":600,"h":1080}"#)
        camera.toggle()
        let left = try #require(run(camera, clock, seconds: 0.1))
        #expect(left.minX == 0, "\(left)")
        send(camera, #"{"t_us":0,"kind":"window","id":2,"x":1400,"y":0,"w":520,"h":1080}"#)
        let right = try #require(run(camera, clock, seconds: 1.0 / 60))
        #expect(abs(right.maxX - 1) < 1e-9, "\(right)")
    }

    /// A pinch or drag holds the view (no crop); a tap hands it back and is
    /// no click; a tap while following is a click.
    @Test func aPinchHoldsAndATapHandsBack() throws {
        let clock = Clock(), camera = camera(clock)
        send(camera, #"{"t_us":0,"kind":"source","w":1920,"h":1080}"#)
        send(camera, #"{"t_us":0,"kind":"window","id":1,"x":0,"y":0,"w":600,"h":1080}"#)
        camera.toggle()
        _ = run(camera, clock, seconds: 0.2)
        #expect(!camera.personTapped(), "following: the tap clicks the Mac")
        camera.personMoved(CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.5))
        #expect(camera.isHeld)
        #expect(camera.crop(at: clock.time, aspect: portrait) == nil, "the person's framing stays")
        #expect(camera.personTapped(), "the tap hands it back")
        #expect(!camera.isHeld && camera.isFollowing)
        let back = try #require(run(camera, clock, seconds: 3))
        #expect(abs(back.width - 0.2) < 1e-6, "keeps the pinched width: \(back)")
        #expect(back.midX < 0.6, "pans back to the window: \(back)")
    }

    @Test func theButtonTurnsOnResumesAndTurnsOff() {
        let clock = Clock(), camera = camera(clock)
        send(camera, #"{"t_us":0,"kind":"source","w":1920,"h":1080}"#)
        camera.toggle()
        #expect(camera.isFollowing)
        camera.personMoved(CGRect(x: 0.1, y: 0, width: 0.3, height: 1))
        camera.toggle()
        #expect(camera.isFollowing && !camera.isHeld, "held: the button resumes")
        camera.toggle()
        #expect(!camera.isFollowing)
        camera.personMoved(CGRect(x: 0.1, y: 0, width: 0.3, height: 1))
        #expect(!camera.isHeld, "off: a pinch is only a pinch")
    }

    /// Reduce Motion: the crop cuts to the caret on the next frame.
    @Test func reduceMotionCuts() throws {
        let clock = Clock(), camera = camera(clock, reduceMotion: true)
        send(camera, #"{"t_us":0,"kind":"source","w":1920,"h":1080}"#)
        send(camera, #"{"t_us":0,"kind":"window","id":1,"x":0,"y":0,"w":1920,"h":1080}"#)
        camera.toggle()
        _ = run(camera, clock, seconds: 0.5)
        send(camera, #"{"t_us":0,"kind":"caret","x":1890,"y":700,"w":2,"h":20}"#)
        let crop = try #require(run(camera, clock, seconds: 2.0 / 60))
        #expect(abs(crop.maxX - 1) < 1e-9, "\(crop)")
    }

    /// A Mac without the Accessibility grant sends damage and the pointer only.
    @Test func followsDamageAndThePointerAlone() throws {
        let clock = Clock(), camera = camera(clock)
        send(camera, #"{"t_us":0,"kind":"source","w":1920,"h":1080}"#)
        camera.toggle()
        _ = run(camera, clock, seconds: 0.1)
        send(camera, #"{"t_us":0,"kind":"damage","x":40,"y":600,"w":120,"h":30}"#)
        let left = try #require(run(camera, clock, seconds: 2))
        #expect(left.minX == 0, "\(left)")
        send(camera, #"{"t_us":0,"kind":"pointer","x":100,"y":600}"#)
        send(camera, #"{"t_us":0,"kind":"pointer","x":1850,"y":600}"#)
        let right = try #require(run(camera, clock, seconds: 2))
        #expect(right.maxX >= 1850.0 / 1920, "\(right)")
    }

    /// Turning the phone makes a new crop shape and keeps the focused window.
    @Test func aRotationKeepsTheFocus() throws {
        let clock = Clock(), camera = camera(clock)
        send(camera, #"{"t_us":0,"kind":"source","w":1920,"h":1080}"#)
        send(camera, #"{"t_us":0,"kind":"window","id":1,"x":1400,"y":0,"w":520,"h":1080}"#)
        camera.toggle()
        _ = run(camera, clock, seconds: 0.1)
        clock.time += 1.0 / 60
        let landscape = try #require(camera.crop(at: clock.time, aspect: 852.0 / 393))
        #expect(abs(landscape.maxX - 1) < 1e-9, "still on the window: \(landscape)")
    }

    @Test func cropShapeMath() {
        let wide = ScreenSharingFollowCamera.crop(widthShare: 0.5, viewAspect: 393.0 / 852,
                                                  source: CGSize(width: 1920, height: 1080))
        #expect(abs(wide.aspect - 960.0 / 1080) < 1e-9 && wide.zoom == 1)
        let tight = ScreenSharingFollowCamera.crop(widthShare: 0.1, viewAspect: 393.0 / 852,
                                                   source: CGSize(width: 1920, height: 1080))
        #expect(abs(tight.aspect - 393.0 / 852) < 1e-9)
        #expect(abs(1080 * tight.aspect / tight.zoom - 192) < 1e-6, "192 px wide")
    }
}
#endif
