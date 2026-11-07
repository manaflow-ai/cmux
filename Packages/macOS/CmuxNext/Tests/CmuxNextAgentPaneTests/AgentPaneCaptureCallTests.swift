import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The capture bar's page-to-native calls (plans/cmux-next/capture-bar-DESIGN.md, "Contract"): how
/// each decodes, that the page host routes them, the recording's name, size and limit, and that
/// Copy and Save take a path only when this bridge wrote it.
struct AgentPaneCaptureCallTests {
    private static func request(_ method: String, _ params: [String: Any] = [:]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test(arguments: ["screen", "window", "app", "pane"])
    func everyScreenshotModeDecodes(_ mode: String) {
        #expect(Self.request("composer.capture", ["mode": mode]) == .capture(.shot(mode: mode)))
        #expect(AgentPaneCapture.modes.contains(mode))
    }

    @Test func recordStartTakesThePointerAndClicks() {
        #expect(Self.request("capture.record.start", ["cursor": false, "clicks": true]) == .capture(.recordStart(cursor: false, clicks: true)))
        // The pointer is drawn unless the page says otherwise; clicks are not.
        #expect(Self.request("capture.record.start") == .capture(.recordStart(cursor: true, clicks: false)))
        #expect(Self.request("capture.record.stop") == .capture(.recordStop))
    }

    @Test func copyTakesAnImagesBytesOrAPath() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(Self.request("capture.copy", ["data": png.base64EncodedString(), "mimeType": "image/png"])
            == .capture(.copy(.bytes(png, mimeType: "image/png"))))
        #expect(Self.request("capture.copy", ["path": "/tmp/a.mp4"]) == .capture(.copy(.file("/tmp/a.mp4"))))
        #expect(Self.request("capture.save", ["path": "/tmp/a.mp4", "name": "Clip.mp4"]) == .capture(.save(.file("/tmp/a.mp4"), name: "Clip.mp4")))
    }

    @Test func copyRefusesWhatNoCaptureIs() {
        let text = Data("hi".utf8).base64EncodedString()
        // Not an image type, not base64, a relative path, both at once, nothing.
        for params: [String: Any] in [["data": text, "mimeType": "text/html"], ["data": "%%", "mimeType": "image/png"],
                                      ["path": "a.mp4"], ["path": "/tmp/a.mp4", "data": text, "mimeType": "image/png"], [:]] {
            #expect(Self.request("capture.copy", params) == .capture(.copy(nil)))
        }
    }

    @Test func aSaveNameIsOnlyItsLastComponent() {
        #expect(AgentPaneCaptureCall.fileName("../../etc/Clip.mp4") == "Clip.mp4")
        #expect(AgentPaneCaptureCall.fileName(".hidden") == nil)
        #expect(AgentPaneCaptureCall.fileName("  ") == nil)
        #expect(AgentPaneCaptureCall.fileName("a\0b") == nil)
    }

    /// The shared page host refuses an op it does not list (`unknown_op`).
    @Test(arguments: ["composer.capture", "capture.record.start", "capture.record.stop", "capture.copy", "capture.save"])
    func thePageHostRoutesEveryCall(_ method: String) {
        #expect(AgentPageOps.method(for: AgentPageOps.namespace + method) == method)
    }

    @Test func aRecordingIsNamedForWhenItStarted() throws {
        let started = try #require(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                                  year: 2026, month: 11, day: 7, hour: 9, minute: 4, second: 5).date)
        #expect(AgentPaneRecorder.name(started) == "Recording 2026-11-07 09.04.05.mp4")
    }

    @Test func aRecordingStopsByItselfAfterFiveMinutes() {
        #expect(AgentPaneRecorder.maxSeconds == 300)
        #expect((30...60).contains(AgentPaneRecorder.framesPerSecond))
    }

    @Test func theMovieIsTheBackingSizeCappedAndEven() {
        let small = AgentPaneRecorder.size(points: CGSize(width: 800, height: 601), scale: 2)
        #expect(small.width == 1600 && small.height == 1202)
        let large = AgentPaneRecorder.size(points: CGSize(width: 1728, height: 1117), scale: 2)
        #expect(large.width == 2560)
        #expect(large.height.isMultiple(of: 2) && large.height <= 1656 && large.height >= 1650)
        let none = AgentPaneRecorder.size(points: .zero, scale: 2)
        #expect(none.width == 2 && none.height == 2)
    }

    /// A page must never make native copy or save an arbitrary file: only a movie this bridge wrote.
    @Test func copyAndSaveTakeOnlyAFileThisBridgeWrote() {
        let folder = URL(fileURLWithPath: "/var/folders/xy/T/cmux-capture", isDirectory: true)
        let movie = "/private/var/folders/xy/T/cmux-capture/ID/Recording 2026-11-07 09.04.05.mp4"
        let written: Set<String> = [movie]
        #expect(AgentPaneRecorder.owned(movie, in: folder, written: written)?.path == movie)
        // Not written by it, though inside its folder; outside the folder; a dotted or relative spelling.
        #expect(AgentPaneRecorder.owned("/private/var/folders/xy/T/cmux-capture/ID/other.mp4", in: folder, written: written) == nil)
        #expect(AgentPaneRecorder.owned("/etc/passwd", in: folder, written: written.union(["/etc/passwd"])) == nil)
        let dotted = "/private/var/folders/xy/T/cmux-capture/ID/../../../../etc/passwd"
        #expect(AgentPaneRecorder.owned(dotted, in: folder, written: written.union([dotted])) == nil)
        #expect(AgentPaneRecorder.owned("cmux-capture/ID/a.mp4", in: folder, written: ["cmux-capture/ID/a.mp4"]) == nil)
    }
}
