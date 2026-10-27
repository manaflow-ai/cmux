import CmuxFuzzSupport
import CmuxHomeCore
import Foundation
import LibFuzzerDriver

/// HomeWireJSON.parse on the raw body or frame a hosted `cmux.wire/1` owner sends (CmuxHomeCore,
/// built here from its Foundation-only file): any bytes give a value or nil, a value's text parses
/// back to the same value, and the field readers never trap.
struct HomeWireJSONProperty {
    func check(_ data: Data) throws {
        guard let value = HomeWireJSON.parse(data) else { return }
        try FuzzRun.check(HomeWireJSON.parse(value.text) == value, "the value's text parses to another value")
        var pending = [value]
        while let next = pending.popLast() {
            _ = (next.uint, next.int, next["id"].string)
            pending += next.array ?? []
            pending += next.object.map { Array($0.values) } ?? []
        }
    }
}

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try HomeWireJSONProperty().check($0) }
}

let target = LibFuzzerTarget(
    corpus: "HomeWireJSON.bytes",
    seeds: [Array(#"{"t":"event","seq":"42","rev":7,"ok":true,"rows":[{"id":"m1","n":-1.5e3},null,"x"]}"#.utf8)]
)
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
