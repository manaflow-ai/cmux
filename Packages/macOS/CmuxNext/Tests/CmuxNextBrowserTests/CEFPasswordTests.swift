import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation
@testable import CmuxNextBrowser
import Foundation
import Testing

/// `cefPasswordRevealCallback`, the `done` that `CEFEngine.revealPassword` hands
/// `cmux_shim_password_reveal`: `copy` sees the bytes once, during the call, and the reveal answers
/// whether a password came; a NULL answer is not found. These cases call the callback as a shim
/// does. The host-mode delivery (a REPLY, or NULL when no answer comes) is tested where it lives:
/// remote_shim_test.cpp (scripts/cmux-next/tests/remote-shim-abi.test.sh).
@MainActor @Suite(.timeLimit(.minutes(1))) struct CEFPasswordTests {
    /// What one reveal's `copy` saw.
    private final class Copies {
        var seen: [[UInt8]] = []
    }

    /// Runs one reveal whose callback gets `bytes` (nil: the shim's NULL), as the shim calls it.
    private func reveal(_ bytes: [UInt8]?) async throws -> (found: Bool, copies: [[UInt8]]) {
        let copies = Copies()
        let found = try await withOnceThrowingContinuation { (continuation: OnceContinuation<Bool, any Error>) in
            // SAFETY: the box calls `copy` only with the callback's live buffer (PasswordRevealBox.finish).
            let box = unsafe PasswordRevealBox(copy: { unsafe copies.seen.append(Array($0)) }, continuation: continuation)
            // SAFETY: the +1 retain is the callback's context; PasswordRevealBox.take takes it back once.
            let context = unsafe Unmanaged.passRetained(box).toOpaque()
            // SAFETY: `context` is the box retained above, passed once, as the shim passes it.
            guard let bytes else { return unsafe cefPasswordRevealCallback(context, nil, 0) }
            bytes.withUnsafeBytes { raw in
                // SAFETY: `raw` holds `raw.count` bytes for this call, as the shim's buffer does during its callback.
                unsafe cefPasswordRevealCallback(context, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
            }
        }
        return (found, copies.seen)
    }

    @Test func aRevealedPasswordIsCopiedOnce() async throws {
        let password = Array("s3cret".utf8)
        let result = try await reveal(password)
        #expect(result.found)
        #expect(result.copies == [password])
    }

    /// done(ctx, NULL, 0): not found, nothing copied.
    @Test func aNullAnswerEndsAsNotFound() async throws {
        let result = try await reveal(nil)
        #expect(!result.found)
        #expect(result.copies.isEmpty)
    }
}
