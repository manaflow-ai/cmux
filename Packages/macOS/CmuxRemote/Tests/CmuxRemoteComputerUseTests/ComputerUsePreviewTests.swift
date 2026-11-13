// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import CmuxRemoteComputerUse
import CmuxRemoteWire
import Darwin
import Foundation
import os
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

    /// A preview session's channel after it ended: a write queued before the close (the encoder's
    /// last frames, a status, a still) must never reach the descriptor number once the next
    /// connection reuses it (round-2 review of f9ff124: agent A's frames landed in B's stream).
    @Test func aWriteAfterCloseNeverReachesAReusedDescriptor() throws {
        var first: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0)
        let channel = LineChannel(socket: first[0])
        let number = first[0]
        channel.shutdown()
        #expect(!channel.write(Data("after shutdown\n".utf8)), "a shut-down channel refuses writes")
        channel.close()
        close(first[1])
        // The next connection gets the lowest free number: the one the closed channel had.
        var second: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0)
        defer { close(second[0]); close(second[1]) }
        let reused = second[0] == number ? second[0] : (second[1] == number ? second[1] : -1)
        try #require(reused >= 0, "the descriptor number was not reused; the test cannot show the race")
        let peer = reused == second[0] ? second[1] : second[0]
        #expect(!channel.write(Data("agent A's frame\n".utf8)), "a closed channel refuses writes")
        channel.close() // a second close must not close the reused number either
        #expect(fcntl(reused, F_GETFD) != -1, "the reused descriptor is still open")
        _ = fcntl(peer, F_SETFL, O_NONBLOCK)
        var byte: UInt8 = 0
        #expect(read(peer, &byte, 1) == -1 && errno == EAGAIN, "nothing reached the reused descriptor")
    }

    /// A writer blocked in a full socket (the peer stopped reading) must not hold up close():
    /// RemoteHost closes the old daemon's channel during a handoff, and a hang there keeps the new
    /// daemon from its hello reply (full review of a0f8d73).
    @Test func closeDoesNotWaitForAWriterStuckInAFullSocket() throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { Darwin.close(fds[1]) }
        let channel = LineChannel(socket: fds[0])
        let wrote = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let writerDone = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        Thread {
            started.signal()
            let ok = channel.write(Data(repeating: 0x41, count: 16 * 1024 * 1024)) // far past the socket buffer
            wrote.withLock { $0 = ok }
            writerDone.signal()
        }.start()
        started.wait()
        #expect(writerDone.wait(timeout: .now() + 0.3) == .timedOut, "the writer is stuck: nobody reads")
        let closed = DispatchSemaphore(value: 0)
        Thread { channel.close(); closed.signal() }.start()
        #expect(closed.wait(timeout: .now() + 5) == .success, "close() returns")
        #expect(writerDone.wait(timeout: .now() + 5) == .success, "and the writer wakes")
        #expect(wrote.withLock { $0 } == false)
        channel.shutdown() // after a close: a no-op, never a reused number
        channel.close()
    }

    /// ScreenCaptureKit slow on the stills path: the session never starts a second still while one
    /// is being captured, however many looks pass, and closing the channel does not wait for it
    /// (round-3 review of a245191: queued captures held `writes`, and the close waited on all of them).
    @Test func aSlowStillNeverPilesUpAndDoesNotHoldTheClose() throws {
        let textEdit = textEdit
        let looks = OSAllocatedUnfairLock(initialState: 0)
        let stills = OSAllocatedUnfairLock(initialState: 0)
        let lookedEnough = DispatchSemaphore(value: 0)
        let (release, releaser) = AsyncStream.makeStream(of: Void.self)
        let capture = PreviewCapture(
            owner: { _ in
                if looks.withLock({ $0 += 1; return $0 }) == 60 { lookedEnough.signal() }
                return textEdit
            },
            bounds: { _ in nil },
            window: { id in throw ScreenCapture.Failure.noWindow(id) }, // no stream: the stills path
            still: { _, _ in
                stills.withLock { $0 += 1 }
                for await _ in release {} // ScreenCaptureKit never answers until the test ends
                return .failure(.captureFailed)
            })
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let request = try #require(PreviewStreamWire.Request(["session": "s1", "long_side": 400]))
        let session = PreviewStreamSession(
            channel: LineChannel(socket: fds[0]), request: request,
            windowOf: { _ in ComputerUsePreview.SessionWindow(window: 9, app: textEdit) }, blocked: { _, _ in false },
            capture: capture,
            timing: PreviewTiming(look: .milliseconds(5), still: 0.001, retryBase: 0.001, retryMax: 0.002, keyframeGap: 0.3))
        let returned = DispatchSemaphore(value: 0)
        Thread { session.run(); returned.signal() }.start()
        #expect(lookedEnough.wait(timeout: .now() + 20) == .success)
        #expect(stills.withLock { $0 } == 1, "one still at a time while it is slow")
        close(fds[1])
        #expect(returned.wait(timeout: .now() + 5) == .success, "the close does not wait for the stuck capture")
        releaser.finish()
    }

    /// Moving to another window, the session says so at once (a `paused` status naming the new
    /// window's generation) before that window's stream or still, so the app drops the old window's
    /// picture even if neither ever comes (round-6 review).
    @Test func anotherWindowIsAnnouncedAtOnce() throws {
        let textEdit = textEdit
        let current = OSAllocatedUnfairLock<UInt32>(initialState: 9)
        let capture = PreviewCapture(
            owner: { _ in textEdit },
            bounds: { _ in nil },
            window: { id in throw ScreenCapture.Failure.noWindow(id) }, // stills only
            still: { _, _ in .success((Data([1, 2, 3]), 1, 1)) })
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = try #require(PreviewStreamWire.Request(["session": "s1", "long_side": 400]))
        let session = PreviewStreamSession(
            channel: LineChannel(socket: fds[0]), request: request,
            windowOf: { _ in ComputerUsePreview.SessionWindow(window: current.withLock { $0 }, app: textEdit) },
            blocked: { _, _ in false }, capture: capture,
            timing: PreviewTiming(look: .milliseconds(5), still: 0.001, retryBase: 10, retryMax: 10, keyframeGap: 0.3))
        let returned = DispatchSemaphore(value: 0)
        Thread { session.run(); returned.signal() }.start()
        func next() -> (kind: UInt8, status: [String: Any]?)? {
            var header = [UInt8](repeating: 0, count: 5)
            guard recv(fds[1], &header, 5, MSG_WAITALL) == 5 else { return nil }
            let length = Int(UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4]))
            var payload = [UInt8](repeating: 0, count: length)
            guard length == 0 || recv(fds[1], &payload, length, MSG_WAITALL) == length else { return nil }
            let status = header[0] == 0x53 ? (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any] : nil
            return (header[0], status)
        }
        let first = try #require(next())
        #expect(first.status?["state"] as? String == "paused" && first.status?["window"] as? Int == 1, "window A is named first")
        // Wait for A's still, then move to window B.
        while let message = next(), message.kind != 0x4A {}
        current.withLock { $0 = 10 }
        var afterSwitch: [(kind: UInt8, status: [String: Any]?)] = []
        while let message = next() {
            afterSwitch.append(message)
            if message.status?["window"] as? Int == 2 { break }
        }
        let announce = try #require(afterSwitch.last)
        #expect(announce.status?["state"] as? String == "paused", "B is named by a paused status before anything of B")
        #expect(afterSwitch.dropLast().allSatisfy { $0.status?["window"] as? Int != 2 })
        close(fds[1])
        #expect(returned.wait(timeout: .now() + 5) == .success)
    }

    /// Keyframes: always the first after a start or a new encoder; asked ones at most every 300 ms.
    @Test func askedKeyframesAreThrottled() {
        var policy = PreviewKeyframePolicy(gap: 0.3)
        let start = Date(timeIntervalSince1970: 100)
        var forced: [Bool] = []
        forced.append(policy.force(now: start)) // a new stream starts with a keyframe
        forced.append(policy.force(now: start.addingTimeInterval(0.01)))
        policy.asked = true
        forced.append(policy.force(now: start.addingTimeInterval(0.1))) // asked within 300 ms: not yet
        forced.append(policy.force(now: start.addingTimeInterval(0.31))) // then once the gap passed
        forced.append(policy.force(now: start.addingTimeInterval(0.32))) // the ask is taken
        policy.required = true
        forced.append(policy.force(now: start.addingTimeInterval(0.33))) // a new encoder forces one whatever the gap
        #expect(forced == [true, false, false, true, false, true])
    }

    @Test func theAppAsksForAnotherSizeWithAnLLine() {
        #expect(PreviewStreamWire.longSide(Data("L 800".utf8)) == 800)
        #expect(PreviewStreamWire.longSide(Data("L 99999".utf8)) == PreviewStreamWire.Request.maximumLongSide)
        #expect(PreviewStreamWire.longSide(Data("L 1".utf8)) == PreviewStreamWire.Request.minimumLongSide)
        #expect(PreviewStreamWire.longSide(Data("K".utf8)) == nil)
        #expect(PreviewStreamWire.longSide(Data("L wide".utf8)) == nil)
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
