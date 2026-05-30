// SPDX-License-Identifier: MIT

import Foundation

/// Constant-time byte-vector compare (Errata E9).
///
/// Returns `false` immediately for length mismatch — the length
/// leak is acceptable per the threat model, the per-byte equality
/// leak is not. For equal-length inputs, every byte is XORed and
/// ORed into a single accumulator, so the total work and timing are
/// independent of where the first mismatch sits.
///
/// Shared by the legacy Unix-socket auth path in
/// `SocketControlSettings.passwordMatches(_:environment:fileURL:…)`
/// and the Phase 1 HTTP bearer-token check in `HTTPAuth`.
///
/// - Parameters:
///   - a: First byte vector.
///   - b: Second byte vector.
/// - Returns: `true` iff both buffers have the same length and
///   contain the same bytes.
public func ctCompare(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    if a.isEmpty { return true }
    var diff: UInt8 = 0
    a.withUnsafeBytes { ap in
        b.withUnsafeBytes { bp in
            let aBuf = ap.bindMemory(to: UInt8.self)
            let bBuf = bp.bindMemory(to: UInt8.self)
            for i in 0..<a.count {
                diff |= aBuf[i] ^ bBuf[i]
            }
        }
    }
    return diff == 0
}
