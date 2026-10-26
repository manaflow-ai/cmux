@testable import CmuxNextBrowser
import Foundation
import Testing

/// The reveal callback both backends call (`cmux_shim_password_reveal`, task p01-process-025): in
/// process the shim calls it on CEF's UI thread; in host mode the remote shim calls it on main with
/// the host's REPLY, or with NULL when the host exits first. Either way `copy` sees the bytes once,
/// during the call, and the reveal answers whether a password came.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CEFPasswordTests {
    /// What one reveal's `copy` saw.
    private final class Copies {
        var seen: [[UInt8]] = []
    }

    /// Runs one reveal whose callback gets `bytes` (nil: the shim's NULL), as the shim calls it.
    private func reveal(_ bytes: [UInt8]?) async throws -> (found: Bool, copies: [[UInt8]]) {
        let copies = Copies()
        let found = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            let box = PasswordRevealBox(copy: { copies.seen.append(Array($0)) }, continuation: continuation)
            let context = Unmanaged.passRetained(box).toOpaque()
            guard let bytes else { return cefPasswordRevealCallback(context, nil, 0) }
            bytes.withUnsafeBytes { raw in
                cefPasswordRevealCallback(context, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
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

    /// The host's exit ends a pending reveal with done(ctx, NULL, 0) (remote_shim_local.mm), as the
    /// fork answers an id it does not have: not found, nothing copied.
    @Test func aRevealTheHostNeverAnsweredEndsAsNotFound() async throws {
        let result = try await reveal(nil)
        #expect(!result.found)
        #expect(result.copies.isEmpty)
    }
}
