import CMUXMobileCore
import Foundation
import LibFuzzerDriver

/// MobileTerminalRenderGridFrame.decode on the raw JSON a Mac sends a phone (CMUXMobileCore), and
/// the VT replay of every frame that decodes: any bytes give a frame inside the size limits or an
/// error, and a frame's replay never traps. The suite's file is linked for its base frames.
struct MobileRenderGridProperty {
    func check(_ data: Data) {
        guard let frame = try? MobileTerminalRenderGridFrame.decode(data) else { return }
        _ = frame.vtPatchBytes()
        _ = frame.vtReplacementBytes()
    }
}

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { MobileRenderGridProperty().check($0) }
}

let target = LibFuzzerTarget(
    corpus: "MobileRenderGrid.bytes",
    seeds: [Array(MobileProtocolFuzzTests.grid), Array(MobileProtocolFuzzTests.scrolledDelta)]
)
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
