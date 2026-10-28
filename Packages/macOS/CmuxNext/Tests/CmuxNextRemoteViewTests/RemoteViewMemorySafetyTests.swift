import CoreGraphics
import CoreMedia
import CoreVideo
@testable import CmuxNextRemoteView
import Foundation
import Testing

/// The remote view's pointer sites after the strict-memory-safety pass: every
/// pointer handed to the rd core, Core Media, VideoToolbox or Core Video stays inside the memory it
/// names, for the lifetime the `// SAFETY:` argument above it claims. Run under ASan
/// (`--sanitize=address`): an out-of-bounds or dangling access fails the run, not only an expectation.
@Suite struct RemoteViewMemorySafetyTests {
    // MARK: rd core wrappers

    /// Key, text and service events reach the core with their bytes, and too long or empty text
    /// is refused without a read past the bytes.
    @Test func inputEventsCarryTheirBytes() throws {
        let input = try #require(RemoteRdInput(carrier: .stream))
        let key = try input.send(.key(usage: 0x0007_0004, down: true))
        let text = try input.send(.text("héllo, wörld"))
        let service = try input.sendService(Data(#"{"t":"key","code":"KeyA"}"#.utf8), mustDeliver: true)
        #expect(key < text && text < service)
        #expect(throws: RemoteRdCoreError.invalid) { try input.send(.text("")) }
        #expect(throws: RemoteRdCoreError.invalid) {
            try input.send(.text(String(repeating: "x", count: RemoteInputEvent.maxTextBytes + 1)))
        }
        #expect(throws: RemoteRdCoreError.invalid) { try input.sendService(Data(), mustDeliver: false) }
        #expect(throws: RemoteRdCoreError.invalid) {
            try input.sendService(Data(count: RemoteRdInput.maxServiceBytes + 1), mustDeliver: false)
        }
        // After the refusals the earlier events still go out.
        #expect(try input.packets(nowMicros: 1).isEmpty == false)
        #expect(try input.send(.key(usage: 0x0007_0004, down: false)) > service)
    }

    /// A control message framed for the stream carrier comes back byte for byte, from a receiver
    /// and from a session, in chunks that split the frame header.
    @Test(arguments: [1, 3, 64]) func controlMessagesRoundTrip(chunk: Int) throws {
        let json = Data(#"{"t":"started","session":7}"#.utf8)
        let frame = try RemoteRdCore.streamFrame(json, control: true)
        let core = try #require(RemoteRdCore(carrier: .stream))
        let session = try #require(RemoteRdSession(carrier: .stream))
        for start in stride(from: 0, to: frame.count, by: chunk) {
            let piece = frame.subdata(in: start..<min(start + chunk, frame.count))
            try core.push(streamBytes: piece, nowMicros: 10)
            try session.push(streamBytes: piece, nowMicros: 10)
        }
        #expect(try core.popMessage() == .control(json))
        #expect(try core.popMessage() == nil)
        #expect(try session.popMessage() == .control(json))
        #expect(try session.popMessage() == nil)
    }

    /// Bulk upload bytes are copied when queued; the receiver refuses bytes that are no chunk.
    @Test func bulkCopiesQueuedBytesAndRefusesGarbage() throws {
        let sender = try #require(RemoteRdBulkSender(intervalMicros: 16_666))
        var data = Data(repeating: 0xAB, count: 4096)
        try sender.queue(transfer: 7, data: data)
        data.resetBytes(in: 0..<data.count)
        #expect(sender.queuedBytes == 4096)
        #expect(throws: RemoteRdCoreError.invalid) { try sender.queue(transfer: 7, data: data) }
        try sender.cancel(transfer: 7)
        #expect(sender.queuedBytes == 0)

        let receiver = try #require(RemoteRdBulkReceiver())
        #expect(throws: RemoteRdCoreError.invalid) { try receiver.accept(Data([1, 2, 3])) }
    }

    // MARK: synthetic frames

    /// The painter writes through bounds-checked planes and copies them in at the buffer's own
    /// stride: the marker reads back from a buffer whose rows are padded past the width.
    @Test(arguments: [(640, 32), (700, 66), (1282, 720)]) func paintedMarkerReadsBack(width: Int, height: Int) throws {
        let buffer = try Self.nv12(width: width, height: height)
        for counter: UInt16 in [0, 1, 0xA5C3, 0xFFFF] {
            SyntheticFramePainter.paint(.init(counter: counter, pointer: CGPoint(x: 300, y: 20)), into: buffer)
            #expect(RemoteFrameMarker.read(buffer) == counter)
        }
    }

    /// A buffer too narrow for the marker gets the rest of the scene and no marker.
    @Test func narrowBufferHasNoMarker() throws {
        let buffer = try Self.nv12(width: 320, height: 200)
        SyntheticFramePainter.paint(.init(counter: 9, pointer: CGPoint(x: 400, y: 400)), into: buffer)
        #expect(RemoteFrameMarker.read(buffer) == nil)
    }

    @Test func planeFillsAndSubscriptsStayInTheirRow() {
        var plane = SyntheticPlane(width: 6, height: 3)
        plane.fill(row: 1, column: 2, count: 3, with: 9)
        plane[2, 5] = 4
        #expect(plane.bytes == [0, 0, 0, 0, 0, 0,
                                0, 0, 9, 9, 9, 0,
                                0, 0, 0, 0, 0, 4])
    }

    // MARK: presenter

    /// The sample-buffer presenter's sample carries display-immediately on its own attachments.
    @MainActor @Test func immediateSampleDisplaysAtOnce() throws {
        let sample = try #require(SampleBufferPresenter.immediateSample(try Self.nv12(width: 64, height: 64)))
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])
        #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    }

    private static func nv12(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
        // SAFETY: Core Video writes one +1 buffer to the local `buffer`, live for the call.
        let status = unsafe CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }
}

#if DEBUG
/// The mock host's whole path: painter, encoder (parameter sets and Annex-B through Core Media's
/// pointers), `RemoteVideoFormat` and the decoder. The frame counter survives into the decoded
/// picture, so every pointer on the way carried the right bytes.
@Suite struct RemoteMockPathMemorySafetyTests {
    @Test(.timeLimit(.minutes(1))) func decodedFramesCarryTheirMarker() async throws {
        let source = MockRemoteStreamSource(width: 1280, height: 720)
        try #require(source.canEncode, "VideoToolbox has no H.264 encoder here")
        let (frames, sink) = AsyncStream.makeStream(of: RemoteDecodedFrame.self)
        let pipeline = RemoteDecodePipeline(source: source, deliver: { sink.yield($0) })
        let units = source.accessUnits()

        for _ in 0..<3 { source.damage() }
        var decoded = 0
        for await unit in units {
            #expect(await pipeline.decode(unit) == .decoded)
            decoded += 1
            if decoded == 3 { break }
        }
        sink.finish()
        var markers: [UInt16?] = []
        var expected: [UInt16?] = []
        for await frame in frames {
            markers.append(RemoteFrameMarker.read(frame.pixelBuffer))
            // The mock advances its counter before it paints a frame: frame n shows n + 1.
            expected.append(UInt16(truncatingIfNeeded: frame.frame &+ 1))
        }
        #expect(markers.count == 3)
        #expect(markers == expected)
    }
}
#endif
