// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CmuxNextComputerUse
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import os
@testable import CmuxNextMacScreen
import Testing
import VideoToolbox

/// The live preview of an agent's Computer Use: which surface a session belongs to, when the
/// preview shows, what the person's gestures do, where it docks, and the app's side of cmux
/// Remote's `computer-use-preview` channel (statuses, stills, real H.264 into the display layer).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ComputerUsePreviewTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: Surfaces and rules

    @Test func sessionKeysNameTheirTerminalOrChat() {
        #expect(ComputerUsePreviewSurface(session: "terminal:term_abc:4242") == .terminal(resource: "term_abc"))
        #expect(ComputerUsePreviewSurface(session: "acp-session-7") == .chat(session: "acp-session-7"))
        #expect(ComputerUsePreviewSurface(session: "unbound-91") == nil)
        #expect(ComputerUsePreviewSurface(session: "") == nil)
        #expect(ComputerUsePreviewSurface(session: "terminal::4242") == nil)
        #expect(ComputerUsePreviewSurface(session: "terminal:term_abc") == nil)
    }

    @Test func theFocusedSurfacesNewestLiveSessionShows() {
        let rules = ComputerUsePreviewRules(lingers: 15)
        let candidates = [
            ComputerUsePreviewCandidate(session: "terminal:term_a:1", lastAction: now.addingTimeInterval(-5)),
            ComputerUsePreviewCandidate(session: "terminal:term_a:2", lastAction: now.addingTimeInterval(-1)),
            ComputerUsePreviewCandidate(session: "terminal:term_b:3", lastAction: now),
            ComputerUsePreviewCandidate(session: "chat-1", lastAction: now, stopped: true),
        ]
        #expect(rules.session(for: .terminal(resource: "term_a"), among: candidates, enabled: true, now: now)?.session == "terminal:term_a:2")
        // Off: nothing shows, whatever acts.
        #expect(rules.session(for: .terminal(resource: "term_a"), among: candidates, enabled: false, now: now) == nil)
        // Nothing focused, a stopped session, another surface's session.
        #expect(rules.session(for: nil, among: candidates, enabled: true, now: now) == nil)
        #expect(rules.session(for: .chat(session: "chat-1"), among: candidates, enabled: true, now: now) == nil)
        #expect(rules.session(for: .chat(session: "chat-2"), among: candidates, enabled: true, now: now) == nil)
        // An agent that has not acted for `lingers` no longer shows.
        let later = now.addingTimeInterval(16)
        #expect(rules.session(for: .terminal(resource: "term_a"), among: candidates, enabled: true, now: later) == nil)
    }

    @Test func aPreviewLingersUntilFifteenSecondsAfterItsLastAction() {
        let rules = ComputerUsePreviewRules()
        let candidate = ComputerUsePreviewCandidate(session: "chat-1", lastAction: now)
        #expect(rules.lingersUntil(candidate, now: now.addingTimeInterval(3)) == now.addingTimeInterval(15))
        #expect(rules.lingersUntil(candidate, now: now.addingTimeInterval(15)) == nil)
    }

    @Test func gesturesMoveBetweenCardExpandedAndHidden() {
        #expect(ComputerUsePreviewPresentation.card.after(.expand) == .expanded)
        #expect(ComputerUsePreviewPresentation.expanded.after(.collapse) == .card)
        #expect(ComputerUsePreviewPresentation.expanded.after(.hide) == .hidden)
        #expect(ComputerUsePreviewPresentation.card.after(.hide) == .hidden)
        #expect(ComputerUsePreviewPresentation.hidden.after(.show) == .card)
        // A hidden preview does not expand from a stray click; a card does not collapse further.
        #expect(ComputerUsePreviewPresentation.hidden.after(.expand) == .hidden)
        #expect(ComputerUsePreviewPresentation.card.after(.collapse) == .card)
    }

    // MARK: Layout

    @Test func theThumbnailDocksTopRightAtTheReferenceInsets() {
        let layout = ComputerUsePreviewLayout(aspect: 16.0 / 10.0)
        let frame = layout.thumbnailFrame(in: CGSize(width: 1000, height: 700))
        #expect(frame.size == CGSize(width: 200, height: 125))
        // 20.5 pt from the right, 24.5 pt below the top (origin bottom left, rounded to points).
        #expect(frame.maxX == (1000 - 20.5).rounded())
        #expect(frame.origin.y == (700 - 24.5 - 125).rounded())
        // A portrait window keeps 200 pt on its long side.
        #expect(ComputerUsePreviewLayout(aspect: 0.5).thumbnailSize(available: 1000) == CGSize(width: 100, height: 200))
    }

    @Test func theThumbnailShrinksWithTheSurfaceAndKeepsItsSizeRange() {
        #expect(ComputerUsePreviewLayout(aspect: 2).thumbnailSize(available: 141) == CGSize(width: 100, height: 50))
        #expect(ComputerUsePreviewLayout(longSide: 900, aspect: 1).thumbnailSize(available: 2000) == CGSize(width: 400, height: 400))
        #expect(ComputerUsePreviewLayout(longSide: 10, aspect: 1).thumbnailSize(available: 2000) == CGSize(width: 120, height: 120))
        // A broken aspect falls back to 16:10 instead of a zero or infinite size.
        #expect(ComputerUsePreviewLayout(aspect: .nan).thumbnailSize(available: 1000) == CGSize(width: 200, height: 125))
    }

    @Test func aDragSnapsToTheNearestCorner() {
        let size = CGSize(width: 800, height: 600)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 700, y: 500), in: size) == .topRight)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 100, y: 500), in: size) == .topLeft)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 700, y: 100), in: size) == .bottomRight)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 100, y: 100), in: size) == .bottomLeft)
        let frame = ComputerUsePreviewLayout(corner: .bottomLeft, aspect: 2).thumbnailFrame(in: size)
        #expect(frame.origin == CGPoint(x: CGFloat(20.5).rounded(), y: CGFloat(20.5).rounded()))
    }

    @Test func theExpandedViewKeepsTheAspectWithinItsShare() {
        let size = ComputerUsePreviewLayout(aspect: 2).expandedSize(in: CGSize(width: 1000, height: 1000))
        #expect(size == CGSize(width: 860, height: 430))
        let tall = ComputerUsePreviewLayout(aspect: 0.5).expandedSize(in: CGSize(width: 1000, height: 1000))
        #expect(tall == CGSize(width: 430, height: 860))
    }

    /// The picture size asked of cmux Remote: the expanded view's is the wire's largest; the card's
    /// twice its pixel long side, 512 to 800.
    @Test func theStreamSizeFollowsThePresentation() {
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: true, cardPoints: 200, backingScale: 2) == 1600)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 200, backingScale: 2) == 800)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 160, backingScale: 2) == 640)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 120, backingScale: 1) == 512)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 400, backingScale: 2) == 800)
    }

    // MARK: The wire

    @Test func statusesParseAndAnUnknownStateIsSkipped() {
        let status = ComputerUsePreviewStatus(["state": "streaming", "width": 1280, "height": 800, "app": ["name": "Safari"]])
        #expect(status == ComputerUsePreviewStatus(state: .streaming, width: 1280, height: 800, appName: "Safari"))
        #expect(ComputerUsePreviewStatus(["state": "no_window"])?.state == .noWindow)
        #expect(ComputerUsePreviewStatus(["state": "blocked", "app": ["name": ""]]) == ComputerUsePreviewStatus(state: .blocked))
        #expect(ComputerUsePreviewStatus(["state": "teleporting"]) == nil)
        #expect(ComputerUsePreviewStatus(["width": 3]) == nil)
    }

    @Test func parameterSetsAndFramesParseAndBrokenOnesDoNot() {
        let sets = ComputerUsePreviewWire.parameterSets(Data([0, 2, 0x67, 0x42, 0, 1, 0x68, 0xFF]))
        #expect(sets?.sps == Data([0x67, 0x42]))
        #expect(sets?.pps == Data([0x68]))
        #expect(ComputerUsePreviewWire.parameterSets(Data([0, 5, 0x67])) == nil)
        #expect(ComputerUsePreviewWire.parameterSets(Data([0, 0, 0, 1, 0x68])) == nil)
        let frame = ComputerUsePreviewWire.frame(Data([1, 0, 0, 0, 0, 0, 0, 1, 0x2C, 9, 8]))
        #expect(frame?.keyframe == true)
        #expect(frame?.microseconds == 300)
        #expect(frame?.avcc == Data([9, 8]))
        #expect(ComputerUsePreviewWire.frame(Data([0, 0, 0, 0, 0, 0, 0, 0, 1])) == nil)
    }

    /// The reader turns the channel's messages into events in order, skips a kind it does not know
    /// (a newer cmux Remote's) and an unknown state, and says when the channel closes.
    @Test func theReaderDeliversStatusesStillsAndTheClose() throws {
        let (ours, theirs) = try socketPair()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        var bytes = message(0x53, Data(#"{"state":"streaming","width":640,"height":400}"#.utf8))
        bytes += message(0x5A, Data([1, 2, 3]))
        bytes += message(0x53, Data(#"{"state":"warp"}"#.utf8))
        bytes += message(0x4A, jpeg)
        bytes += message(0x53, Data(#"{"state":"blocked"}"#.utf8))
        #expect(bytes.withUnsafeBytes { write(theirs, $0.baseAddress, $0.count) } == bytes.count)
        close(theirs)
        let seen = Collected()
        ComputerUsePreviewStream.read(ours) { seen.add($0) }
        close(ours)
        #expect(seen.events == [.status(ComputerUsePreviewStatus(state: .streaming, width: 640, height: 400)), .still(jpeg),
                                .status(ComputerUsePreviewStatus(state: .blocked)), .closed])
    }

    /// A payload past the wire's limit ends the stream instead of allocating it.
    @Test func anOversizedMessageClosesTheStream() throws {
        let (ours, theirs) = try socketPair()
        let header: [UInt8] = [0x4A, 0x7F, 0xFF, 0xFF, 0xFF]
        #expect(write(theirs, header, header.count) == header.count)
        let seen = Collected()
        ComputerUsePreviewStream.read(ours) { seen.add($0) }
        close(theirs)
        close(ours)
        #expect(seen.events == [.closed])
    }

    /// Parameter sets and a frame on the wire become one ready sample, delivered after the status
    /// that came before it; the main side enqueues it into the display layer.
    @Test func framesOnTheWireBecomeSamplesForTheLayer() throws {
        let encoded = try encodeOneFrame(width: 320, height: 200)
        let (ours, theirs) = try socketPair()
        var parameters = Data()
        for set in [encoded.sps, encoded.pps] { parameters += Data([UInt8(set.count >> 8), UInt8(set.count & 0xFF)]) + set }
        var bytes = message(0x53, Data(#"{"state":"streaming","width":320,"height":200}"#.utf8))
        bytes += message(0x46, Data([1, 0, 0, 0, 0, 0, 0, 0, 1]) + encoded.avcc) // a frame before the format: skipped
        bytes += message(0x50, parameters)
        bytes += message(0x46, Data([1, 0, 0, 0, 0, 0, 0, 0x82, 0x35]) + encoded.avcc)
        #expect(bytes.withUnsafeBytes { write(theirs, $0.baseAddress, $0.count) } == bytes.count)
        close(theirs)
        let seen = Collected()
        ComputerUsePreviewStream.read(ours) { seen.add($0) }
        close(ours)
        #expect(seen.kinds == ["status", "sample", "closed"])
        let sample = try #require(seen.samples.first)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 33_333, timescale: 1_000_000))
        var events: [ComputerUsePreviewStream.Event] = []
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { events.append($0) }
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .streaming))))
        stream.receive(.sample(sample))
        #expect(stream.displayLayer.sampleBufferRenderer.status != .failed)
        events.removeAll()
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .blocked))))
        #expect(events == [.status(ComputerUsePreviewStatus(state: .blocked))])
    }

    /// Real hardware H.264 from VideoToolbox (as cmux Remote encodes it) crosses the wire's `P` and
    /// `F` messages and becomes a sample the display layer takes, shown at once.
    @Test func realH264BecomesADisplayableSample() throws {
        let encoded = try encodeOneFrame(width: 320, height: 200)
        var parameters = Data()
        for set in [encoded.sps, encoded.pps] {
            parameters += Data([UInt8(set.count >> 8), UInt8(set.count & 0xFF)]) + set
        }
        let sets = try #require(ComputerUsePreviewWire.parameterSets(parameters))
        let format = try #require(ComputerUsePreviewStream.format(sps: sets.sps, pps: sets.pps))
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 320)
        #expect(dimensions.height == 200)
        var framePayload = Data([1])
        let micros: UInt64 = 33_333
        for shift in stride(from: 56, through: 0, by: -8) { framePayload.append(UInt8(micros >> UInt64(shift) & 0xFF)) }
        framePayload += encoded.avcc
        let frame = try #require(ComputerUsePreviewWire.frame(framePayload))
        #expect(frame.keyframe)
        let sample = try #require(ComputerUsePreviewStream.sample(frame.avcc, format: format, microseconds: frame.microseconds))
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 33_333, timescale: 1_000_000))
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])
        #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
        let layer = AVSampleBufferDisplayLayer()
        layer.sampleBufferRenderer.enqueue(sample)
        #expect(layer.sampleBufferRenderer.status != .failed)
    }

    /// After `blocked` the picture stays off: stills are refused, and a later paused or no_window
    /// status does not bring them back; only `streaming` or `still` does.
    @Test func afterBlockedNoStillShowsUntilTheWindowMayShowAgain() {
        var events: [ComputerUsePreviewStream.Event] = []
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { events.append($0) }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        stream.receive(.event(.still(jpeg)))
        #expect(events.isEmpty, "no still before the worker says one may show")
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .still))))
        stream.receive(.event(.still(jpeg)))
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .blocked))))
        stream.receive(.event(.still(jpeg)))
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .paused))))
        stream.receive(.event(.still(jpeg)))
        #expect(events == [.status(ComputerUsePreviewStatus(state: .still)), .still(jpeg),
                           .status(ComputerUsePreviewStatus(state: .blocked)), .status(ComputerUsePreviewStatus(state: .paused))])
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .streaming))))
        stream.receive(.event(.still(jpeg)))
        #expect(events.suffix(2) == [.status(ComputerUsePreviewStatus(state: .streaming)), .still(jpeg)])
    }

    /// Frames show only while the worker says `streaming`: after `blocked` (or any other status)
    /// no frame reaches the layer until the next `streaming`, and a closed channel clears the layer.
    @Test func framesShowOnlyWhileStreaming() throws {
        let encoded = try encodeOneFrame(width: 320, height: 200)
        let format = try #require(ComputerUsePreviewStream.format(sps: encoded.sps, pps: encoded.pps))
        let sample = try #require(ComputerUsePreviewStream.sample(encoded.avcc, format: format, microseconds: 1))
        var events: [ComputerUsePreviewStream.Event] = []
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { events.append($0) }
        stream.receive(.sample(sample))
        #expect(stream.framesShown == 0, "a frame before any status is not shown")
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .streaming))))
        stream.receive(.sample(sample))
        #expect(stream.framesShown == 1)
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .blocked))))
        stream.receive(.sample(sample))
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .paused))))
        stream.receive(.sample(sample))
        #expect(stream.framesShown == 1, "no frame after blocked, nor after a later paused")
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .streaming))))
        stream.receive(.sample(sample))
        #expect(stream.framesShown == 2, "streaming again shows frames again")
        #expect(events.count == 4)
        stream.receive(.event(.closed))
        #expect(events.last == .closed)
    }

    /// Nothing reaches the presenter after `stop()`: no late frame, still or close of the old
    /// channel (a close would schedule a reopen of a stream nobody wants).
    @Test func nothingIsDeliveredAfterStop() {
        var events: [ComputerUsePreviewStream.Event] = []
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { events.append($0) }
        stream.receive(.event(.status(ComputerUsePreviewStatus(state: .streaming))))
        stream.stop()
        stream.receive(.event(.still(Data([1]))))
        stream.receive(.event(.closed))
        #expect(events == [.status(ComputerUsePreviewStatus(state: .streaming))])
    }

    /// A busy main thread: at three frames waiting the reader drops frames, then every frame until
    /// the next keyframe, so the decoder never gets a frame whose reference it lost.
    @Test func aBusyMainThreadDropsFramesUntilAKeyframe() throws {
        let encoded = try encodeOneFrame(width: 320, height: 200)
        let (ours, theirs) = try socketPair()
        var parameters = Data()
        for set in [encoded.sps, encoded.pps] { parameters += Data([UInt8(set.count >> 8), UInt8(set.count & 0xFF)]) + set }
        func frame(_ keyframe: Bool, _ time: UInt8) -> Data {
            message(0x46, Data([keyframe ? 1 : 0, 0, 0, 0, 0, 0, 0, 0, time]) + encoded.avcc)
        }
        // Times 1-3 pass; the backlog is full at 4 and 5 (a delta, then a delta while it has room
        // again), and the keyframe at 6 resumes the stream.
        var bytes = message(0x50, parameters)
        for (key, time) in [(true, 1), (false, 2), (false, 3), (false, 4), (false, 5), (true, 6), (false, 7)] as [(Bool, UInt8)] {
            bytes += frame(key, time)
        }
        #expect(bytes.withUnsafeBytes { write(theirs, $0.baseAddress, $0.count) } == bytes.count)
        close(theirs)
        let seen = Collected()
        // The reader asks for the backlog before each frame it may pass: full only at the 4th ask
        // (frame 4); frame 5 is not asked about (it waits for a keyframe), frame 6 finds room.
        let asks = OSAllocatedUnfairLock(initialState: 0)
        var keyframeRequests = 0
        ComputerUsePreviewStream.read(ours, backlog: {
            asks.withLock { $0 += 1; return $0 == 4 ? ComputerUsePreviewStream.maximumPendingSamples : 0 }
        }, askKeyframe: { keyframeRequests += 1 }) { seen.add($0) }
        close(ours)
        let times = seen.samples.map { CMSampleBufferGetPresentationTimeStamp($0).value }
        #expect(times == [1, 2, 3, 6, 7])
        #expect(keyframeRequests == 1, "one keyframe request when it starts dropping")
    }

    // MARK: Helpers

    /// What the reader delivered, in order (the reader runs on the test's thread here).
    private nonisolated final class Collected: Sendable {
        private let lock = OSAllocatedUnfairLock<[ComputerUsePreviewStream.Output]>(initialState: [])
        var outputs: [ComputerUsePreviewStream.Output] { lock.withLock { $0 } }
        func add(_ output: ComputerUsePreviewStream.Output) { lock.withLock { $0.append(output) } }
        var events: [ComputerUsePreviewStream.Event] {
            outputs.compactMap { if case .event(let event) = $0 { event } else { nil } }
        }
        var samples: [CMSampleBuffer] {
            outputs.compactMap { if case .sample(let sample) = $0 { sample } else { nil } }
        }
        var kinds: [String] {
            outputs.map {
                switch $0 {
                case .sample: "sample"
                case .event(.closed): "closed"
                case .event(.still): "still"
                case .event(.status): "status"
                }
            }
        }
    }

    private func message(_ kind: UInt8, _ payload: Data) -> Data {
        let n = UInt32(payload.count)
        return Data([kind, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + payload
    }

    private func socketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        return (fds[0], fds[1])
    }

    private nonisolated struct Encoded: Sendable {
        var sps: Data
        var pps: Data
        var avcc: Data
    }

    private func encodeOneFrame(width: Int32, height: Int32) throws -> Encoded {
        var session: VTCompressionSession?
        #expect(VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                           encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                           outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr)
        let compressor = try #require(session)
        defer { VTCompressionSessionInvalidate(compressor) }
        VTSessionSetProperty(compressor, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(compressor, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var pixels: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        let buffer = try #require(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * Int(height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let output = OutputBox()
        let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        #expect(VTCompressionSessionEncodeFrame(compressor, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                                                frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            if status == noErr, let sample { output.take(sample) }
        } == noErr)
        #expect(VTCompressionSessionCompleteFrames(compressor, untilPresentationTimeStamp: .invalid) == noErr)
        return try #require(output.encoded)
    }

    /// The encoder's one output, taken apart in its callback (CMSampleBuffer is not Sendable).
    private nonisolated final class OutputBox: Sendable {
        private let lock = OSAllocatedUnfairLock<Encoded?>(initialState: nil)
        var encoded: Encoded? { lock.withLock { $0 } }
        func take(_ sample: CMSampleBuffer) {
            guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample),
                  let sps = Self.parameterSet(format, 0), let pps = Self.parameterSet(format, 1) else { return }
            var avcc = Data(count: CMBlockBufferGetDataLength(block))
            let copied = avcc.withUnsafeMutableBytes { bytes in
                bytes.baseAddress.map { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: $0) }
                    ?? kCMBlockBufferBadPointerParameterErr
            }
            guard copied == noErr else { return }
            let encoded = Encoded(sps: sps, pps: pps, avcc: avcc)
            lock.withLock { $0 = encoded }
        }

        private static func parameterSet(_ format: CMFormatDescription, _ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}
