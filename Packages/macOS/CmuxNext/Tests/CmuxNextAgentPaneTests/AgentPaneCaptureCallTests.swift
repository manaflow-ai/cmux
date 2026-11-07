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
        #expect(AgentPaneRecorder.owned(movie, in: [folder], written: written)?.path == movie)
        // Not written by it, though inside its folder; outside the folder; a dotted or relative spelling.
        #expect(AgentPaneRecorder.owned("/private/var/folders/xy/T/cmux-capture/ID/other.mp4", in: [folder], written: written) == nil)
        #expect(AgentPaneRecorder.owned("/etc/passwd", in: [folder], written: written.union(["/etc/passwd"])) == nil)
        let dotted = "/private/var/folders/xy/T/cmux-capture/ID/../../../../etc/passwd"
        #expect(AgentPaneRecorder.owned(dotted, in: [folder], written: written.union([dotted])) == nil)
        #expect(AgentPaneRecorder.owned("cmux-capture/ID/a.mp4", in: [folder], written: ["cmux-capture/ID/a.mp4"]) == nil)
    }

    /// Movies nobody attached go after a day: kept ones, the one starting and recent ones stay.
    @Test func theSweepRemovesOnlyOldFoldersNotKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        for name in ["kept", "stale", "fresh"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["kept", "stale"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        AgentPaneRecorder.sweep(root, keeping: ["kept"], now: Date())
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["fresh", "kept"])
    }

    /// A handed-out movie moves into its chat's upload folder, out of the folder the sweep clears,
    /// and its temporary folder goes; a move that fails leaves the movie where it was.
    @Test func aCollectedMovieMovesIntoItsChatUploadFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("capture/ID/Recording.mp4")
        try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: movie)
        let upload = root.appendingPathComponent("uploads/sessions/S/U")
        let kept = try #require(AgentPaneRecorder.keep(movie, in: upload))
        #expect(kept == upload.appendingPathComponent("Recording.mp4"))
        #expect(try Data(contentsOf: kept) == Data("movie".utf8))
        #expect(!FileManager.default.fileExists(atPath: movie.deletingLastPathComponent().path))
        #expect(AgentPaneRecorder.owned(kept.path, in: [root.appendingPathComponent("capture"), root.appendingPathComponent("uploads")], written: [kept.path]) == kept)
        // A movie that is gone: nothing moves and no upload folder is left.
        let other = root.appendingPathComponent("uploads/sessions/S/V")
        #expect(AgentPaneRecorder.keep(movie, in: other) == nil)
        #expect(!FileManager.default.fileExists(atPath: other.path))
        // An upload folder that already exists is another upload's: it is not used, and it stays whole.
        let again = movie.deletingLastPathComponent().appendingPathComponent("Again.mp4")
        try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: again)
        #expect(AgentPaneRecorder.keep(again, in: upload) == nil)
        #expect(try Data(contentsOf: kept) == Data("movie".utf8))
        #expect(FileManager.default.fileExists(atPath: again.path))
    }

    /// A moved window is filmed where it is now: its part of the display, from the display's corner.
    @Test func theStreamFollowsTheWindowOnItsDisplay() {
        let display = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(AgentPaneRecording.source(CGRect(x: 1540, y: 50, width: 800, height: 600), on: display) == CGRect(x: 100, y: 50, width: 800, height: 600))
        // Half off the display's right edge: only what the display shows.
        #expect(AgentPaneRecording.source(CGRect(x: 3000, y: 0, width: 800, height: 600), on: display)?.width == 360)
        #expect(AgentPaneRecording.source(CGRect(x: 0, y: 0, width: 800, height: 600), on: display) == nil)
    }

    /// Save writes beside the destination and renames over it: the old file is replaced whole, and
    /// a failed save leaves it and no partial file.
    @Test func saveReplacesTheDestinationAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Shot.png")
        try Data("old".utf8).write(to: destination)
        #expect(AgentPaneCapture.write(bytes: Data("new".utf8), file: nil, to: destination))
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        // A source that is gone: the destination stays as it was.
        #expect(!AgentPaneCapture.write(bytes: nil, file: root.appendingPathComponent("missing.mp4"), to: destination))
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Shot.png"])
        // A link in the movie's place is refused, never followed: the destination keeps its bytes.
        let secret = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = root.appendingPathComponent("movie.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(!AgentPaneCapture.write(bytes: nil, file: link, to: destination))
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        // A regular movie copies.
        let movie = root.appendingPathComponent("real.mp4")
        try Data("movie".utf8).write(to: movie)
        #expect(AgentPaneCapture.write(bytes: nil, file: movie, to: destination))
        #expect(try Data(contentsOf: destination) == Data("movie".utf8))
    }
}
