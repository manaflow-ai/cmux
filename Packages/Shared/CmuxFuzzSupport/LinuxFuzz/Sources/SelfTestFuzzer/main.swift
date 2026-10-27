import CmuxFuzzSupport
import Foundation
import LibFuzzerDriver
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class Node {
    var next: Node?
}

/// The finding classifier's check (swift-libfuzzer.sh --self-test), not a cmux decoder: the first
/// input byte picks a finding. `c` traps, `p` fails a property, `o` asks for more memory than the
/// malloc limit, `t` waits for a signal forever (libFuzzer's timeout alarm ends it), `l` leaks a
/// retain cycle; anything else is clean but fills a lazy static first, which LeakSanitizer must
/// not report (lsan-suppressions.txt).
struct SelfTestFindings {
    static let lazyStatic = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })

    func check(_ data: Data) throws {
        switch data.first {
        case UInt8(ascii: "c"):
            let empty: [Int] = []
            _ = empty[data.count]
        case UInt8(ascii: "p"):
            try FuzzRun.check(data.isEmpty, "the self-test's property case")
        case UInt8(ascii: "o"):
            let huge = [UInt8](repeating: 1, count: 1 << 30)
            _ = huge.last
        case UInt8(ascii: "t"):
            while true { pause() }
        case UInt8(ascii: "l"):
            let first = Node(), second = Node()
            first.next = second
            second.next = first
        default:
            _ = Self.lazyStatic.count
        }
    }
}

// lint:allow free-function: libFuzzer calls a C symbol, and @_cdecl applies only to a global func.
@_cdecl("LLVMFuzzerTestOneInput")
func testOneInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    // SAFETY: libFuzzer passes `count` readable bytes at `bytes` for this call.
    unsafe LibFuzzerTarget.test(bytes, count) { try SelfTestFindings().check($0) }
}

let target = LibFuzzerTarget(corpus: "SelfTest")
// SAFETY: testOneInput is the C entry above; libFuzzer calls it with its own input buffers.
unsafe target.main(testOneInput)
