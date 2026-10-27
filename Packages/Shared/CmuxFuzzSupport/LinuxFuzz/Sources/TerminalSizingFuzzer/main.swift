import Foundation
import LibFuzzerDriver

// TerminalSizingOperationFuzzTests.oneInput (CmuxTerminalSizing): an operation sequence on known
// and unknown ids, its choices read from the input. The suite's file is linked into this target.

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try TerminalSizingOperationFuzzTests.oneInput($0) }
}

let target = LibFuzzerTarget(corpus: "TerminalSizing.oneInput", seeds: [[]])
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
