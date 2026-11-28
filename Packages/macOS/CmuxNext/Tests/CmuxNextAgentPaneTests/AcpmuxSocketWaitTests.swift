import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ``AcpmuxSocketWait`` ends at readiness or at the caller's cancel, and only returns once its
/// dispatch source has let go of the descriptor, so the caller may close it right away (#46746:
/// the source's cancel handler used to be set after activation, which crashed the queue's drain).
/// The crash was a race inside libdispatch, so no test here reproduces it deterministically; these
/// pin the contract and run many rounds of the paths that raced.
@Suite struct AcpmuxSocketWaitTests {
    /// A connected socket pair; `writable` has room, `readable` has one byte waiting when `filled`.
    private static func pair(filled: Bool) throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        if filled {
            var byte: UInt8 = 1
            guard Darwin.write(fds[1], &byte, 1) == 1 else { throw POSIXError(.EIO) }
        }
        return (fds[0], fds[1])
    }

    @Test func aReadableDescriptorEndsTheWait() async throws {
        let (reader, writer) = try Self.pair(filled: true)
        defer { Darwin.close(reader); Darwin.close(writer) }
        try await AcpmuxSocketWait.ready(reader, forWrite: false)
    }

    @Test func aWritableDescriptorEndsTheWait() async throws {
        let (reader, writer) = try Self.pair(filled: false)
        defer { Darwin.close(reader); Darwin.close(writer) }
        try await AcpmuxSocketWait.ready(writer, forWrite: true)
    }

    /// Nothing to read: only the caller's cancel ends the wait, with `CancellationError`.
    @Test func theCallersCancelEndsTheWait() async throws {
        let (reader, writer) = try Self.pair(filled: false)
        defer { Darwin.close(reader); Darwin.close(writer) }
        let wait = Task { try await AcpmuxSocketWait.ready(reader, forWrite: false) }
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
    }

    /// The peer closing its end (the daemon exited) makes the descriptor readable: the wait ends.
    @Test func thePeerClosingEndsTheWait() async throws {
        let (reader, writer) = try Self.pair(filled: false)
        defer { Darwin.close(reader) }
        Darwin.close(writer)
        try await AcpmuxSocketWait.ready(reader, forWrite: false)
    }

    /// Many concurrent waits that end at readiness (a source that keeps firing) or at a cancel,
    /// each closing its descriptors the moment the wait returns, as the acpmux exchange does.
    @Test func manyWaitsEndAndReleaseTheirDescriptors() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for round in 0..<400 {
                group.addTask {
                    let (reader, writer) = try Self.pair(filled: round % 3 != 0)
                    defer { Darwin.close(reader); Darwin.close(writer) }
                    switch round % 3 {
                    case 0:
                        let wait = Task { try await AcpmuxSocketWait.ready(reader, forWrite: false) }
                        wait.cancel()
                        _ = try? await wait.value
                    case 1:
                        try await AcpmuxSocketWait.ready(reader, forWrite: false)
                    default:
                        try await AcpmuxSocketWait.ready(writer, forWrite: true)
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
