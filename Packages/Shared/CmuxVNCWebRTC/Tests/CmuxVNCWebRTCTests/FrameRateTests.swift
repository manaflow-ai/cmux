@testable import CmuxVNCWebRTC
import Foundation
import Testing
import WebRTC

/// 120 Hz streaming: the frame rate both sides agree on, the encoding it
/// asks for, and the messages that carry it between old and new peers.
struct FrameRateTests {
    /// Without the rules (cmux-rd-screen `screen_quality_encoding`, whose tests hold the rates,
    /// bitrates and scale-down) a host keeps libwebrtc's own sender parameters at 60 fps.
    @Test func withoutTheRulesThereIsNoEncoding() {
        for quality in ScreenQuality.allCases {
            #expect(quality.encoding(sourceWidth: 3456, sourceHeight: 2234, hostMaximum: 120, viewerMaximum: 120, rules: ScreenRules()) == nil)
        }
    }

    /// The caller asks the op with the preset, the display and both rates, and reads the answer
    /// as cmux-rd-screen sends it (its json_tests' answers).
    @Test func theEncodingIsTheRulesAnswer() throws {
        let rules = ScreenRules { operation, data in
            guard operation == "screen_quality_encoding",
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            switch request["quality"] as? String {
            case "auto":
                guard request["sourceWidth"] as? Int == 3456, request["sourceHeight"] as? Int == 2234,
                      request["hostMaximum"] as? Int == 120, request["viewerMaximum"] as? Int == 120 else { return nil }
                return Data(#"{"frameRate":120,"encoding":{"degradation":"maintainResolution","maxBitrate":24000000,"minBitrate":null,"maxFramerate":120,"scaleDown":1.6}}"#.utf8)
            case "low":
                guard request["hostMaximum"] == nil, request["viewerMaximum"] == nil else { return nil }
                return Data(#"{"frameRate":30,"encoding":{"degradation":"disabled","maxBitrate":1500000,"minBitrate":1500000,"maxFramerate":30,"scaleDown":2.0}}"#.utf8)
            default:
                return nil
            }
        }
        let auto = try #require(ScreenQuality.auto.encoding(sourceWidth: 3456, sourceHeight: 2234, hostMaximum: 120, viewerMaximum: 120, rules: rules))
        #expect(auto.frameRate == 120)
        #expect(auto.settings == ScreenQuality.Settings(degradation: .maintainResolution, maxBitrate: 24_000_000, minBitrate: nil,
                                                        maxFramerate: 120, scaleDown: 1.6))
        #expect(auto.settings.degradation.preference == .maintainResolution)
        let low = try #require(ScreenQuality.low.encoding(sourceHeight: 1440, rules: rules))
        #expect(low.frameRate == 30 && low.settings.minBitrate == 1_500_000 && low.settings.scaleDown == 2)
        #expect(low.settings.degradation.preference == .disabled)
        #expect(ScreenQuality.medium.encoding(rules: rules) == nil, "an answer the rules do not give is none")
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
