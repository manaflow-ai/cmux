// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CmuxNextComputerUse
import CmuxNextDaemon
import CmuxNextActions
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import os
@testable import CmuxNextMacScreen
import Testing
import VideoToolbox

/// The app's side of cmux Remote's `computer-use-preview` channel: statuses, stills and the
/// close off the wire, real H.264 into the display layer, window changes and backpressure.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ComputerUsePreviewStreamTests {
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

    /// The reader turns the channel's messages into outputs in order, skips a kind it does not know
    /// (a newer cmux Remote's), an unknown state and a still that does not decode, and says when the
    /// channel closes. Stills are decoded on the reader's thread into one slot: two before the main
    /// queue takes one tell it once (the slot keeps the newest; aStaleStillWordTakesNothing).
    @Test func theReaderDeliversStatusesStillsAndTheClose() throws {
        let (ours, theirs) = try socketPair()
        var bytes = message(0x53, Data(#"{"state":"streaming","width":640,"height":400}"#.utf8))
        bytes += message(0x5A, Data([1, 2, 3]))
        bytes += message(0x53, Data(#"{"state":"warp"}"#.utf8))
        bytes += message(0x4A, Data([0xFF, 0xD8, 0xFF, 0xD9])) // not a picture: dropped
        bytes += message(0x4A, try jpeg(width: 40, height: 20))
        bytes += message(0x4A, try jpeg(width: 64, height: 32))
        bytes += message(0x53, Data(#"{"state":"blocked"}"#.utf8))
        #expect(bytes.withUnsafeBytes { write(theirs, $0.baseAddress, $0.count) } == bytes.count)
        close(theirs)
        let seen = Collected()
        let stills = ComputerUsePreviewStillSlot()
        ComputerUsePreviewStream.read(ours, stills: stills) { seen.add($0) }
        close(ours)
        #expect(seen.kinds == ["status", "still", "status", "closed"])
        #expect(stills.take(sequence: 1) == nil, "`blocked`, read after both stills, emptied the slot in wire order")
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
        #expect(seen.kinds == ["closed"])
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
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming)))
        stream.receive(.sample(sample))
        #expect(stream.displayLayer.sampleBufferRenderer.status != .failed)
        #expect(events == [.status(ComputerUsePreviewStatus(state: .streaming)), .pictured], "the first frame says there is a picture")
        events.removeAll()
        stream.receive(.status(ComputerUsePreviewStatus(state: .blocked)))
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
    @Test func afterBlockedNoStillShowsUntilTheWindowMayShowAgain() throws {
        var events: [ComputerUsePreviewStream.Event] = []
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { events.append($0) }
        let picture = try jpeg(width: 40, height: 20)
        func still() {
            if let sequence = stream.stills.put(jpeg: picture) { stream.receive(.stillReady(sequence: sequence)) }
        }
        func stills() -> Int { events.filter { if case .still = $0 { true } else { false } }.count }
        still()
        #expect(events.isEmpty, "no still before the worker says one may show")
        stream.receive(.status(ComputerUsePreviewStatus(state: .still)))
        still()
        #expect(stills() == 1)
        stream.receive(.status(ComputerUsePreviewStatus(state: .blocked)))
        still()
        stream.receive(.status(ComputerUsePreviewStatus(state: .paused)))
        still()
        #expect(stills() == 1, "none after blocked, nor after a later paused")
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming)))
        still()
        #expect(stills() == 2, "streaming again lets stills show")
    }

    /// A word about a still is good only for that still or a newer one: after the slot was emptied
    /// (`blocked`, a close) an old word takes nothing, even when a newer still came in since.
    @Test func aStaleStillWordTakesNothing() throws {
        let slot = ComputerUsePreviewStillSlot()
        let first = try #require(slot.put(jpeg: try jpeg(width: 10, height: 10)))
        #expect(slot.put(jpeg: try jpeg(width: 20, height: 10)) == nil, "one word for a slot that is not empty")
        slot.clear()
        let third = try #require(slot.put(jpeg: try jpeg(width: 30, height: 10)))
        #expect(third > first)
        #expect(slot.take(sequence: first) == nil, "a word from before the slot was emptied takes nothing")
        #expect(slot.take(sequence: third)?.width == 30, "the word about the newest still takes it")
        // Without an emptying, the one word takes the newest still.
        let fourth = try #require(slot.put(jpeg: try jpeg(width: 40, height: 10)))
        #expect(slot.put(jpeg: try jpeg(width: 50, height: 10)) == nil)
        #expect(slot.take(sequence: fourth)?.width == 50)
    }

    /// Another window streaming (a new `window` generation) clears the old window's last frame, so
    /// the overlay hides until the new window's first frame; a resize of the same window does not.
    @Test func anotherWindowClearsTheOldFrame() throws {
        let encoded = try encodeOneFrame(width: 320, height: 200)
        let format = try #require(ComputerUsePreviewStream.format(sps: encoded.sps, pps: encoded.pps))
        let sample = try #require(ComputerUsePreviewStream.sample(encoded.avcc, format: format, microseconds: 1))
        var events: [ComputerUsePreviewStream.Event] = []
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { events.append($0) }
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming, window: 1)))
        stream.receive(.sample(sample))
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming, width: 640, height: 400, window: 1)))
        stream.receive(.sample(sample))
        #expect(events.filter { $0 == .pictured }.count == 1, "the same window resized keeps its picture")
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming, window: 2)))
        stream.receive(.sample(sample))
        #expect(events.filter { $0 == .pictured }.count == 2, "another window starts a new picture")
        #expect(ComputerUsePreviewStatus(["state": "streaming", "window": 2])?.window == 2)
    }

    /// The reader empties the still slot in wire order: a still read before another window's
    /// status (or `blocked`) is never shown, and the new window's first still, read after it, is not
    /// dropped (round-6 review: clearing on the main thread could drop B's first still).
    @Test func theReaderEmptiesTheSlotInWireOrder() throws {
        let (ours, theirs) = try socketPair()
        var bytes = message(0x53, Data(#"{"state":"still","window":1}"#.utf8))
        bytes += message(0x4A, try jpeg(width: 40, height: 20)) // window A
        bytes += message(0x53, Data(#"{"state":"paused","window":2}"#.utf8))
        bytes += message(0x4A, try jpeg(width: 64, height: 32)) // window B's first
        #expect(bytes.withUnsafeBytes { write(theirs, $0.baseAddress, $0.count) } == bytes.count)
        close(theirs)
        let seen = Collected()
        let stills = ComputerUsePreviewStillSlot()
        ComputerUsePreviewStream.read(ours, stills: stills) { seen.add($0) }
        close(ours)
        let words = seen.outputs.compactMap { if case .stillReady(let sequence) = $0 { sequence } else { nil } }
        #expect(words.count == 2)
        #expect(stills.take(sequence: words[0]) == nil, "A's still, read before B's status, is gone")
        #expect(stills.take(sequence: words[1])?.width == 64, "B's first still is kept")
    }

    /// Which statuses change the window: any that names another one, and (to fail safe with an
    /// older cmux Remote) a `streaming` or `still` naming none once one was named.
    @Test func whichStatusesChangeTheWindow() {
        var shown: Int?
        #expect(!ComputerUsePreviewStream.changesWindow(&shown, ComputerUsePreviewStatus(state: .streaming, window: 1)))
        #expect(!ComputerUsePreviewStream.changesWindow(&shown, ComputerUsePreviewStatus(state: .still, window: 1)))
        #expect(ComputerUsePreviewStream.changesWindow(&shown, ComputerUsePreviewStatus(state: .paused, window: 2)))
        #expect(!ComputerUsePreviewStream.changesWindow(&shown, ComputerUsePreviewStatus(state: .noWindow)))
        #expect(ComputerUsePreviewStream.changesWindow(&shown, ComputerUsePreviewStatus(state: .streaming)), "no window named: fail safe")
        #expect(shown == nil)
        #expect(!ComputerUsePreviewStream.changesWindow(&shown, ComputerUsePreviewStatus(state: .streaming)))
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
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming)))
        stream.receive(.sample(sample))
        #expect(stream.framesShown == 1)
        stream.receive(.status(ComputerUsePreviewStatus(state: .blocked)))
        stream.receive(.sample(sample))
        stream.receive(.status(ComputerUsePreviewStatus(state: .paused)))
        stream.receive(.sample(sample))
        #expect(stream.framesShown == 1, "no frame after blocked, nor after a later paused")
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming)))
        stream.receive(.sample(sample))
        #expect(stream.framesShown == 2, "streaming again shows frames again")
        #expect(events.filter { $0 == .pictured }.count == 2, "a picture after the start, and again after blocked")
        stream.receive(.closed)
        #expect(events.last == .closed)
    }

    /// Nothing reaches the presenter after `stop()`: no late frame, still or close of the old
    /// channel (a close would schedule a reopen of a stream nobody wants).
    @Test func nothingIsDeliveredAfterStop() throws {
        var events: [ComputerUsePreviewStream.Event] = []
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { events.append($0) }
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming)))
        stream.stop()
        let sequence = try #require(stream.stills.put(jpeg: try jpeg(width: 4, height: 4)))
        stream.receive(.stillReady(sequence: sequence))
        stream.receive(.closed)
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
}
