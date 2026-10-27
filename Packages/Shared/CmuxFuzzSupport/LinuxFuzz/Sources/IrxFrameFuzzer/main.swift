import Foundation
import LibFuzzerDriver

// IrxFrameFuzzTests.oneInput (CmuxIrxTransport): the event-lane frame aligner over any byte stream
// in any chunking, its choices read from the input. The suite's file is linked into this target;
// the aligner comes from the Foundation-only CmuxIrxTransport subset target.

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try IrxFrameFuzzTests.oneInput($0) }
}

// The suite's seed tapes: even bytes go to anyBytes, odd ones to alignedChunking.
let target = LibFuzzerTarget(corpus: "IrxFrame.oneInput", seeds: [[0], [1]])
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
