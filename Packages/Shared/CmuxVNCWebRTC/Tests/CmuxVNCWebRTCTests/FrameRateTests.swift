@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// 120 Hz streaming: the frame rate both sides agree on, the encoding it
/// asks for, and the messages that carry it between old and new peers.
struct FrameRateTests {
    /// Auto and Smooth Motion run at the lower of the two displays' rates, at most 120.
    @Test(arguments: [ScreenQuality.auto, .smooth])
    func adaptivePresetsFollowBothDisplays(quality: ScreenQuality) {
        #expect(quality.frameRate(hostMaximum: 120, viewerMaximum: 120) == 120)
        #expect(quality.frameRate(hostMaximum: 120, viewerMaximum: 60) == 60)
        #expect(quality.frameRate(hostMaximum: 60, viewerMaximum: 120) == 60)
        #expect(quality.frameRate(hostMaximum: 144, viewerMaximum: 144) == 120, "capped at 120")
        #expect(quality.frameRate(hostMaximum: 120, viewerMaximum: 90) == 90)
        #expect(quality.frameRate(hostMaximum: 100, viewerMaximum: 120) == 100)
    }

    /// A peer that does not report a rate (an older viewer, the Screen Sharing
    /// source, a display that says 0) leaves the stream at 60, as before.
    @Test(arguments: [ScreenQuality.auto, .smooth])
    func anUnreportedRateKeepsSixty(quality: ScreenQuality) {
        #expect(quality.frameRate(hostMaximum: 120, viewerMaximum: nil) == 60)
        #expect(quality.frameRate(hostMaximum: nil, viewerMaximum: 120) == 60)
        #expect(quality.frameRate(hostMaximum: nil, viewerMaximum: nil) == 60)
        #expect(quality.frameRate(hostMaximum: 0, viewerMaximum: 120) == 60)
        // Never below today's 60, even on a slower display.
        #expect(quality.frameRate(hostMaximum: 50, viewerMaximum: 120) == 60)
        #expect(quality.frameRate(hostMaximum: 120, viewerMaximum: 30) == 60)
    }

    /// The fixed presets keep their own rate whatever the displays can do.
    @Test func fixedPresetsIgnoreTheDisplays() {
        for (host, viewer) in [(120, 120), (60, 60), (Optional<Int>.none, Optional<Int>.none)] as [(Int?, Int?)] {
            #expect(ScreenQuality.low.frameRate(hostMaximum: host, viewerMaximum: viewer) == 30)
            #expect(ScreenQuality.medium.frameRate(hostMaximum: host, viewerMaximum: viewer) == 30)
            #expect(ScreenQuality.high.frameRate(hostMaximum: host, viewerMaximum: viewer) == 60)
        }
    }

    /// At 120 fps Auto and Smooth Motion may use twice the bitrate, so each
    /// frame keeps the same budget (200 kbit); at 60 nothing changes.
    @Test func adaptiveBitrateScalesWithTheFrameRate() {
        for quality in [ScreenQuality.auto, .smooth] {
            let sixty = quality.settings(sourceHeight: 1800, frameRate: 60)
            #expect(sixty == quality.settings(sourceHeight: 1800), "60 fps is today's encoding")
            #expect(sixty.maxFramerate == 60 && sixty.maxBitrate == 12_000_000)
            let oneTwenty = quality.settings(sourceHeight: 1800, frameRate: 120)
            #expect(oneTwenty.maxFramerate == 120)
            #expect(oneTwenty.maxBitrate == 24_000_000)
            #expect(oneTwenty.degradation == sixty.degradation && oneTwenty.scaleDown == sixty.scaleDown)
            let ninety = quality.settings(sourceHeight: 1800, frameRate: 90)
            #expect(ninety.maxFramerate == 90 && ninety.maxBitrate == 18_000_000)
        }
    }

    /// Above 60 fps Auto and Smooth Motion scale the picture down just enough
    /// for the hardware H.264 encoder to keep up (measured: an M1 Max encodes
    /// a 3456×2234 display at 55 fps, an M4 Pro at 66; both hold 2160×1396 at
    /// 120). At 60 fps and for a display that already fits, nothing changes.
    @Test(arguments: [ScreenQuality.auto, .smooth])
    func aboveSixtyThePictureFitsTheEncoder(quality: ScreenQuality) {
        let budget = Double(ScreenQuality.maximumEncodedPixelRate)
        for (width, height, fps) in [(3456, 2234, 120), (3024, 1964, 120), (3456, 2234, 90), (5120, 2880, 120)] {
            let settings = quality.settings(sourceWidth: width, sourceHeight: height, frameRate: fps)
            let rate = Double(width) / settings.scaleDown * (Double(height) / settings.scaleDown) * Double(fps)
            #expect(rate <= budget * 1.001, "\(width)x\(height) at \(fps) fps asks for \(Int(rate / 1e6)) Mpixel/s")
            #expect(rate >= budget * 0.99, "\(width)x\(height) at \(fps) fps is scaled no more than it needs")
            #expect(settings.maxFramerate == fps && settings.degradation == quality.settings(sourceHeight: height).degradation)
        }
        #expect(quality.settings(sourceWidth: 3456, sourceHeight: 2234, frameRate: 60).scaleDown == 1, "60 fps keeps the full size")
        #expect(quality.settings(sourceWidth: 1920, sourceHeight: 1080, frameRate: 120).scaleDown == 1, "1080p fits at 120")
        #expect(quality.settings(sourceWidth: 0, sourceHeight: 2234, frameRate: 120).scaleDown == 1, "an unknown size is not scaled")
    }

    @Test func fixedPresetsScaleAsBeforeAtAnyRate() {
        for quality in [ScreenQuality.low, .medium, .high] {
            #expect(quality.settings(sourceWidth: 3456, sourceHeight: 2234, frameRate: 120) == quality.settings(sourceHeight: 2234))
        }
    }

    /// The fixed presets' encoding does not depend on the frame rate passed.
    @Test func fixedPresetEncodingIsUnchanged() {
        for quality in [ScreenQuality.low, .medium, .high] {
            #expect(quality.settings(sourceHeight: 2160, frameRate: 120) == quality.settings(sourceHeight: 2160))
        }
        #expect(ScreenQuality.high.settings(sourceHeight: 2160).maxFramerate == 60)
        #expect(ScreenQuality.low.settings(sourceHeight: 2160).maxFramerate == 30)
    }

    /// The viewer reports its display's rate on the input channel; the host
    /// reads it (and ignores anything that is not a sane rate).
    @Test func theViewerReportsItsDisplayRate() throws {
        let input = ScreenStreamViewer.frameRateInput(120)
        let json = try #require(String(data: JSONEncoder().encode(input), encoding: .utf8))
        let decoded = try JSONDecoder().decode(ScreenInput.self, from: Data(json.utf8))
        #expect(ScreenStreamHost.reportedFrameRate(decoded) == 120)
        #expect(ScreenStreamHost.reportedFrameRate(ScreenInput(t: "fps", i: 0)) == nil)
        #expect(ScreenStreamHost.reportedFrameRate(ScreenInput(t: "fps")) == nil)
        #expect(ScreenStreamHost.reportedFrameRate(ScreenInput(t: "fps", i: 100_000)) == nil)
        #expect(ScreenStreamHost.reportedFrameRate(ScreenInput(t: "display", i: 120)) == nil)
    }

    /// The report is never input to the Mac: a view-only host's input path
    /// passes none of it to the source (the session reads it before that path).
    @Test func aViewOnlyHostPassesNoReportAsInput() {
        let backend = RecordingBackend()
        let host = ScreenStreamHost(name: "Studio", viewOnly: true, backend: { backend }, log: { _ in })
        host.deliver(ScreenStreamViewer.frameRateInput(120), to: backend)
        #expect(backend.handled.isEmpty, "a view-only host passes no unknown message to the Mac")
        #expect(backend.selected.isEmpty)
    }

    /// The host's display message carries the agreed rate; a viewer that
    /// predates it decodes the message as before, and a new viewer reads no
    /// rate from an old host.
    @Test func theDisplaysMessageCarriesTheRateCompatibly() throws {
        let message = ScreenHostMessage(t: "displays", displays: [.init(w: 3024, h: 1964)], current: 0, name: "Studio", fps: 120)
        let data = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["fps"] as? Int == 120)
        // An older viewer's message type has no `fps`: it still decodes.
        struct OldHostMessage: Decodable { var t: String; var displays: [ScreenHostMessage.Display]?; var current: Int?; var name: String? }
        let old = try JSONDecoder().decode(OldHostMessage.self, from: data)
        #expect(old.t == "displays" && old.current == 0 && old.displays?.first?.w == 3024 && old.name == "Studio")
        // An older host sends no `fps`.
        let fromOldHost = try JSONDecoder().decode(ScreenHostMessage.self,
                                                   from: Data(#"{"t":"displays","displays":[{"w":1920,"h":1080}],"current":0,"name":"Mini"}"#.utf8))
        #expect(fromOldHost.fps == nil)
        #expect(fromOldHost.displays == [.init(w: 1920, h: 1080)])
    }

    /// A source that does not know its display's rate (the Screen Sharing
    /// loopback, a test double) reports none and ignores a requested rate.
    @Test func backendsWithoutARateKeepTheDefaults() {
        let backend = RecordingBackend()
        #expect(backend.maximumFrameRate == nil)
        backend.setFrameRate(120)
        #expect(backend.handled.isEmpty)
    }

    #if os(macOS)
    /// ScreenCaptureKit captures at the agreed rate (never below 60) and keeps
    /// more surfaces in flight at 120 so the encoder never starves it.
    @Test func captureFollowsTheAgreedRate() {
        #expect(ScreenCaptureBackend.captureFrameRate(for: 120) == 120)
        #expect(ScreenCaptureBackend.captureFrameRate(for: 90) == 90)
        #expect(ScreenCaptureBackend.captureFrameRate(for: 60) == 60)
        #expect(ScreenCaptureBackend.captureFrameRate(for: 30) == 60, "fixed presets capture at 60 as before")
        #expect(ScreenCaptureBackend.queueDepth(for: 60) == 4)
        #expect(ScreenCaptureBackend.queueDepth(for: 120) == 6)
    }
    #endif
}
