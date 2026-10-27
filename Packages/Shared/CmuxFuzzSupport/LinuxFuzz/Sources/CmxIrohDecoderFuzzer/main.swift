import Foundation
import LibFuzzerDriver

// CmxIrohDecoderFuzzTests.oneInput (CmuxIrohTransport): stream headers, terminal output envelopes,
// LAN TXT records and socket addresses, admission acknowledgements, its choices read from the
// input. The suite's file is linked into this target; the decoders come from the Foundation-only
// CmuxIrohTransport subset target.

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try CmxIrohDecoderFuzzTests.oneInput($0) }
}

// One tape per branch of the suite's oneInput (the suite adds encoded headers at run time).
let target = LibFuzzerTarget(corpus: "CmxIrohDecoder.oneInput", seeds: [[0, 0], [0, 1], [1], [2], [3], [4]])
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
