import Foundation
import LibFuzzerDriver

// MobileProtocolFuzzTests.oneInput (CMUXMobileCore): every decoder a paired Mac, phone or relay
// feeds, its choices read from the input. The suite's file is linked into this target.

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try MobileProtocolFuzzTests.oneInput($0) }
}

// The suite's seed tapes: one per branch (the render grid branch once per base).
let target = LibFuzzerTarget(
    corpus: "MobileProtocol.oneInput",
    seeds: [[0], [1], [2, 0], [2, 1], [3], [4], [5], [6], [7]]
)
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
