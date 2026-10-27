import CMUXMobileCore
import CmuxFuzzSupport
import Foundation
import LibFuzzerDriver

/// The two length-prefixed framings a paired peer's stream goes through (CMUXMobileCore), on the
/// raw bytes: MobileSyncFrameCodec.decodeFrames and MobileTerminalInputFrame.decode. Any bytes give
/// frames, a typed error or a wait for more. The sync frames taken, framed again, and the bytes
/// left are the input, in order, and never more frames than the limit.
struct MobileSyncFrameProperty {
    /// The first byte sets the frame limit; the rest is the stream.
    func check(_ data: Data) throws {
        guard let limitByte = data.first else { return }
        let stream = Data(data.dropFirst())
        let limit = 1 + Int(limitByte % 16)
        var remaining = stream
        if let frames = try? MobileSyncFrameCodec.decodeFrames(
            from: &remaining, maximumFrameByteCount: 4_096, maximumDecodedFrameCount: limit
        ) {
            try FuzzRun.check(frames.count <= limit, "\(frames.count) frames past the limit \(limit)")
            var framed = Data()
            for frame in frames { framed += try MobileSyncFrameCodec.encodeFrame(frame) }
            try FuzzRun.check(framed + remaining == stream, "the frames and the rest are not the input")
        }
        var input = stream
        _ = try? MobileTerminalInputFrame.decode(from: &input)
    }
}

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try MobileSyncFrameProperty().check($0) }
}

// A frame limit byte, then a whole two-byte frame and a partial header.
let target = LibFuzzerTarget(corpus: "MobileSyncFrame.bytes", seeds: [[3, 0, 0, 0, 2, 0x68, 0x69, 0, 0]])
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
