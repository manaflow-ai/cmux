import CmuxFuzzSupport
import CmuxTerminalStream
import Foundation
import LibFuzzerDriver

/// The viewer side of terminal-snapshot-v1 (CmuxTerminalStream) on the raw bytes of a channel: each
/// length-prefixed record is one `terminal_bytes` frame body. A frame decodes or throws, a decoded
/// frame encodes back to the same frame, and the viewer takes any frame order; it never feeds more
/// bytes than the frame carried.
struct TerminalStreamProperty {
    func check(_ data: Data) throws {
        var viewer = TerminalViewer(terminal: "fuzz", snapshotVersion: 1, makeRequestID: { "fuzz" })
        var rest = data[...]
        while let length = rest.first {
            let body = Data(rest.dropFirst().prefix(Int(length)))
            rest = rest.dropFirst(1 + body.count)
            guard let frame = try? TerminalFrame(decoding: body) else { continue }
            try FuzzRun.check(try TerminalFrame(decoding: frame.encoded) == frame, "a frame did not round-trip")
            for action in viewer.receive(frame, localDigest: { Data(repeating: 0, count: 32) }) {
                if case .feed(let bytes) = action {
                    try FuzzRun.check(
                        bytes.count <= frame.payload.count,
                        "fed \(bytes.count) bytes of a \(frame.payload.count)-byte frame"
                    )
                }
            }
        }
    }
}

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try TerminalStreamProperty().check($0) }
}

// A READY at offset 3 (generation 1, version 1), then bytes that continue it.
let ready: [UInt8] = [1, 1, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0x61]
let bytesFrame: [UInt8] = [0, 1, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0x62, 0x63]
let target = LibFuzzerTarget(
    corpus: "TerminalStream.frames",
    seeds: [[UInt8(ready.count)] + ready + [UInt8(bytesFrame.count)] + bytesFrame]
)
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
