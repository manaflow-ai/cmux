// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ConstantTimeCompareTests {
    @Test func returnsTrueForEqualBytes() {
        let a = Data(repeating: 0xAA, count: 64)
        let b = Data(repeating: 0xAA, count: 64)
        #expect(ctCompare(a, b))
    }

    @Test func returnsFalseForUnequalBytes() {
        var a = Data(repeating: 0xAA, count: 64)
        var b = Data(repeating: 0xAA, count: 64)
        b[63] = 0xBB
        #expect(!ctCompare(a, b))
        a[0] = 0xCC
        #expect(!ctCompare(a, b))
    }

    @Test func returnsFalseForLengthMismatch() {
        let a = Data(repeating: 0xAA, count: 64)
        let b = Data(repeating: 0xAA, count: 65)
        #expect(!ctCompare(a, b))
    }

    @Test func returnsTrueForTwoEmptyBuffers() {
        #expect(ctCompare(Data(), Data()))
    }

    /// Statistical timing characterization: the helper must touch
    /// every byte of equal-length inputs, so total time is
    /// independent of WHERE the mismatch sits. A short-circuiting
    /// `==` would make `mismatchAtIndex0` finish much faster than
    /// `mismatchAtLastIndex`. The tolerance is loose because CI is
    /// noisy, but a true short-circuit shows up as a > 10x gap, well
    /// outside the 50% delta threshold below.
    @Test func equalLengthCompareTouchesEveryByte() {
        let n = 8192
        let a = Data(repeating: 0xAA, count: n)
        let earlyMismatch = Data([0xBB]) + Data(repeating: 0xAA, count: n - 1)
        let lateMismatch = Data(repeating: 0xAA, count: n - 1) + Data([0xBB])
        let early = measure { _ = ctCompare(a, earlyMismatch) }
        let late = measure { _ = ctCompare(a, lateMismatch) }
        let ratio = abs(early - late) / max(early, late)
        #expect(ratio < 0.5, "ctCompare must scan full length; ratio=\(ratio)")
    }

    private func measure(_ body: () -> Void) -> Double {
        let start = ContinuousClock().now
        for _ in 0..<5000 { body() }
        let dur = start.duration(to: ContinuousClock().now)
        let comps = dur.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1.0e18
    }
}
