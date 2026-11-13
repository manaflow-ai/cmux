// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import CmuxRemoteComputerUse
import CmuxRemoteWire
import Foundation
import Testing
import VideoToolbox

/// The app's live preview stream (`computer-use-preview`): which window it may show, how the stream
/// starts, moves and stops, and its wire.
@Suite struct ComputerUsePreviewTests {
    private typealias App = ComputerUseActivity.App
    private let textEdit = App(id: "com.apple.TextEdit", name: "TextEdit", pid: 42)

    private func place(_ window: UInt32, _ app: App?) -> ComputerUsePreview.SessionWindow {
        ComputerUsePreview.SessionWindow(window: window, app: app)
    }

    @Test func onlyTheSessionsOwnAllowedWindowIsShown() {
        let allow: (String, String) -> Bool = { _, _ in false }
        // The session's window, its app allowed: that window.
        #expect(ComputerUsePreview.gate(window: place(9, textEdit), owner: textEdit, blocked: allow) == .success(9))
        // No window yet, or it is gone.
        #expect(ComputerUsePreview.gate(window: nil, owner: textEdit, blocked: allow) == .failure(.noWindow))
        #expect(ComputerUsePreview.gate(window: place(9, textEdit), owner: nil, blocked: allow) == .failure(.noWindow))
        // Another process owns the window id now: not the session's window.
        let relaunched = App(id: "com.apple.TextEdit", name: "TextEdit", pid: 41)
        #expect(ComputerUsePreview.gate(window: place(9, textEdit), owner: relaunched, blocked: allow) == .failure(.noWindow))
        // The pid is unknown on one side: the bundle id still has to match.
        let noPid = App(id: "com.apple.TextEdit", name: "TextEdit")
        #expect(ComputerUsePreview.gate(window: place(9, noPid), owner: textEdit, blocked: allow) == .success(9))
    }

    /// Defense in depth for agent B's terminal never showing agent A's window: the app the session
    /// captured must be known and own the window now.
    @Test func aWindowOfAnotherOrAnUnknownAppIsNotTheSessions() {
        let allow: (String, String) -> Bool = { _, _ in false }
        let mail = App(id: "com.apple.mail", name: "Mail", pid: 70)
        #expect(ComputerUsePreview.gate(window: place(9, textEdit), owner: mail, blocked: allow) == .failure(.noWindow))
        #expect(ComputerUsePreview.gate(window: place(9, nil), owner: mail, blocked: allow) == .failure(.noWindow))
        #expect(ComputerUsePreview.gate(window: place(9, App(id: nil, name: "Mail")), owner: mail, blocked: allow) == .failure(.noWindow))
    }

    /// A slow app: at most three frames wait for the channel; then frames are dropped until a
    /// keyframe that fits (asked for at once, and again if one had to be dropped), so the app never
    /// gets a frame whose reference it lost.
    @Test func aSlowReaderDropsFramesUntilAKeyframe() {
        var backlog = PreviewFrameBacklog()
        let first = [backlog.admit(keyframe: true, limit: 3), backlog.admit(keyframe: false, limit: 3), backlog.admit(keyframe: false, limit: 3)]
        #expect(first == [true, true, true])
        #expect(backlog.pending == 3 && !backlog.wantsKeyframe)
        let fourth = backlog.admit(keyframe: false, limit: 3)
        #expect(!fourth, "a fourth waiting frame is dropped")
        let asked = backlog.takeKeyframeRequest(), askedAgain = backlog.takeKeyframeRequest()
        #expect(backlog.dropping && asked && !askedAgain)
        backlog.pending = 1
        let delta = backlog.admit(keyframe: false, limit: 3)
        #expect(!delta, "room again, but a delta frame still waits for a keyframe")
        backlog.pending = 3
        let tightKeyframe = backlog.admit(keyframe: true, limit: 3)
        #expect(!tightKeyframe, "a keyframe that does not fit is dropped too")
        let askedOnceMore = backlog.takeKeyframeRequest()
        #expect(askedOnceMore, "and another is asked for")
        backlog.pending = 2
        let keyframe = backlog.admit(keyframe: true, limit: 3)
        #expect(keyframe, "a keyframe that fits resumes the stream")
        #expect(!backlog.dropping && backlog.pending == 3)
    }

    @Test func aBlockedOrUnnamedAppIsNeverShown() {
        var asked: [String] = []
        let denied: (String, String) -> Bool = { id, _ in
            asked.append(id)
            return id == "com.apple.Terminal"
        }
        let terminal = App(id: "com.apple.Terminal", name: "Terminal", pid: 5)
        #expect(ComputerUsePreview.gate(window: place(3, terminal), owner: terminal, blocked: denied) == .failure(.blocked))
        #expect(asked == ["com.apple.Terminal"])
        // An app with no bundle id cannot be checked against the deny list: not shown, not asked.
        let anonymous = App(id: nil, name: "helper", pid: 6)
        #expect(ComputerUsePreview.gate(window: place(4, anonymous), owner: anonymous, blocked: denied) == .failure(.blocked))
        #expect(asked == ["com.apple.Terminal"])
    }

    @Test func theStreamStartsMovesAndStopsWithTheSessionsWindow() {
        // Nothing streams, the window is allowed: start it.
        #expect(PreviewStreamStep.next(streaming: nil, gate: .success(7)) == .start(7))
        // The same window: keep the stream (no new keyframe, no new capture).
        #expect(PreviewStreamStep.next(streaming: 7, gate: .success(7)) == .keep)
        // The agent moved to another window: stream that one.
        #expect(PreviewStreamStep.next(streaming: 7, gate: .success(8)) == .restart(8))
        // The window became private, closed or went away: stop.
        #expect(PreviewStreamStep.next(streaming: 7, gate: .failure(.blocked)) == .stop(.blocked))
        #expect(PreviewStreamStep.next(streaming: 7, gate: .failure(.noWindow)) == .stop(.noWindow))
        #expect(PreviewStreamStep.next(streaming: nil, gate: .failure(.noWindow)) == .stop(.noWindow))
        // The app drops the picture for a private window, keeps it (paused) otherwise.
        #expect(PreviewStreamStep.state(for: .blocked) == "blocked")
        #expect(PreviewStreamStep.state(for: .noWindow) == "no_window")
        #expect(PreviewStreamStep.state(for: .captureFailed) == "paused")
    }

    @Test func framesFitTheLongSideAndNeverScaleUp() {
        let wide = ComputerUsePreview.fitted(width: 1280, height: 800, longSide: 640)
        #expect(wide.width == 640 && wide.height == 400)
        let tall = ComputerUsePreview.fitted(width: 600, height: 1200, longSide: 640)
        #expect(tall.width == 320 && tall.height == 640)
        let small = ComputerUsePreview.fitted(width: 300, height: 200, longSide: 640)
        #expect(small.width == 300 && small.height == 200)
        let empty = ComputerUsePreview.fitted(width: 0, height: 0, longSide: 640)
        #expect(empty.width == 1 && empty.height == 1)
    }

    @Test func theWireFramesEachMessage() throws {
        let status = PreviewStreamWire.status(["state": "streaming"])
        #expect(status.first == PreviewStreamWire.status)
        #expect(status.subdata(in: 1..<5) == Data([0, 0, 0, UInt8(status.count - 5)]))
        let object = try #require(try JSONSerialization.jsonObject(with: status.dropFirst(5)) as? [String: Any])
        #expect(object["state"] as? String == "streaming")

        let sets = PreviewStreamWire.parameterSets(sps: Data([1, 2, 3]), pps: Data([4, 5]))
        #expect(sets.first == PreviewStreamWire.parameterSets)
        #expect(Array(sets.dropFirst(5)) == [0, 3, 1, 2, 3, 0, 2, 4, 5])

        let frame = PreviewStreamWire.frame(keyframe: true, microseconds: 258, avcc: Data([9, 9]))
        #expect(frame.first == PreviewStreamWire.frame)
        #expect(Array(frame.dropFirst(5)) == [1, 0, 0, 0, 0, 0, 0, 1, 2, 9, 9])
    }

    @Test func theRequestNamesASessionAndClampsItsSize() {
        #expect(PreviewStreamWire.Request(["session": "s1", "long_side": 640])?.longSide == 640)
        #expect(PreviewStreamWire.Request(["session": "s1"])?.longSide == PreviewStreamWire.Request.defaultLongSide)
        #expect(PreviewStreamWire.Request(["session": "s1", "long_side": 99_999])?.longSide == PreviewStreamWire.Request.maximumLongSide)
        #expect(PreviewStreamWire.Request(["session": "s1", "long_side": 1])?.longSide == PreviewStreamWire.Request.minimumLongSide)
        #expect(PreviewStreamWire.Request(["long_side": 640]) == nil)
        #expect(PreviewStreamWire.Request(nil) == nil)
    }

    @Test func theConfigureLineCarriesThePreviewSocket() throws {
        let configuration = WorkerConfiguration(policy: Data("{}".utf8), socket: "/tmp/w-cu.sock", secret: String(repeating: "ab", count: 16),
                                                stateDirectory: "/tmp/state", machine: "m", previewSocket: "/tmp/w-cu-preview.sock")
        let object = try #require(try JSONSerialization.jsonObject(with: configuration.line) as? [String: Any])
        #expect(WorkerConfiguration(line: object)?.previewSocket == "/tmp/w-cu-preview.sock")
        // An older host names none; a relative path is refused.
        var older = object
        older["preview_socket"] = nil
        #expect(WorkerConfiguration(line: older)?.previewSocket == nil)
        older["preview_socket"] = "relative.sock"
        #expect(WorkerConfiguration(line: older)?.previewSocket == nil)
    }

    @Test func aJPEGStillEncodesFromAnImage() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = try #require(context.makeImage())
        let jpeg = try #require(ComputerUsePreview.jpeg(image))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func aHardwareEncoderStartsForAPreviewSize() {
        // Every fleet Mac has a hardware H.264 encoder; the session is made and released.
        let encoder = PreviewStreamSession.makeEncoder(width: 640, height: 400)
        #expect(encoder != nil)
        if let encoder { VTCompressionSessionInvalidate(encoder) }
    }
}
