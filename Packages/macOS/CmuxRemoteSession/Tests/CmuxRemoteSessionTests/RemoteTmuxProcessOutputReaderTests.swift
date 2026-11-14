import Foundation
import Testing

@testable import CmuxRemoteSession

/// The reader's bounds are flow control: a consumer that falls behind slows the transport down
/// instead of ending the stream.
@Suite struct RemoteTmuxProcessOutputReaderTests {
    /// A transport that delivers faster than the parser releases must slow down, not end the
    /// stream: ending it is what turned a burst after a network drop into a full reconnect.
    @Test(.timeLimit(.minutes(1))) func readerStopsReadingWhileTheConsumerHoldsAFullBuffer() async throws {
        let pipe = Pipe()
        let bound = 1000
        let reader = RemoteTmuxProcessOutputReader(
            label: "remote-tmux-process-output-reader-held-test",
            maxPendingChunks: 64,
            maxPendingBytes: bound
        )
        let held = HeldOutputChunks()
        reader.attach(to: pipe.fileHandleForReading)
        let capture = Task.detached {
            var data = Data()
            for await chunk in reader.stream {
                data.append(chunk)
                if held.holdOrRelease(chunk) { reader.release(chunk) }
            }
            return data
        }
        defer {
            reader.close()
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        // The reader announces the pause. The consumer task may still be taking the chunks
        // published before it, so their total is polled against a deadline; the consumer holds
        // every chunk, so the reader cannot resume while this waits.
        var pauses = reader.pauses.makeAsyncIterator()
        #expect(await pauses.next() != nil)
        let deadline = ContinuousClock.now + .seconds(30)
        while held.byteCount < bound, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(held.byteCount == bound)
        for chunk in held.stopHolding() { reader.release(chunk) }

        #expect(await capture.value == payload)
    }

    /// A connection tearing down can let go of a paused reader before its queued close runs, and
    /// that close holds the reader weakly. The reader still has to cancel its suspended read
    /// source, which Dispatch traps on releasing, and end its streams.
    @Test(.timeLimit(.minutes(1))) func releasingAPausedReaderEndsItsStream() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        var reader: RemoteTmuxProcessOutputReader? = RemoteTmuxProcessOutputReader(
            label: "remote-tmux-process-output-reader-released-test",
            maxPendingChunks: 64,
            maxPendingBytes: 100
        )
        let stream = try #require(reader?.stream)
        var pauses = try #require(reader?.pauses.makeAsyncIterator())
        reader?.attach(to: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 1, count: 1_000))
        #expect(await pauses.next() != nil)

        reader = nil

        var received = 0
        for await chunk in stream { received += chunk.count }
        #expect(received == 100)
    }

    @Test(.timeLimit(.minutes(1))) func processExitDrainsEveryByteToASlowConsumer() async throws {
        let pipe = Pipe()
        let reader = RemoteTmuxProcessOutputReader(
            label: "remote-tmux-process-output-reader-slow-drain-test",
            maxPendingChunks: 2,
            maxPendingBytes: 1000
        )
        reader.attach(to: pipe.fileHandleForReading)
        let capture = Task.detached {
            var data = Data()
            for await chunk in reader.stream {
                data.append(chunk)
                try? await Task.sleep(for: .milliseconds(2))
                reader.release(chunk)
            }
            return data
        }
        defer {
            reader.close()
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        reader.processDidExit()

        #expect(await capture.value == payload)
    }
}

/// Chunks a test consumer keeps unreleased until the test lets go of them.
private final class HeldOutputChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var holding = true

    var byteCount: Int {
        lock.withLock { chunks.reduce(0) { $0 + $1.count } }
    }

    /// Keeps the chunk while holding; returns true when the caller should release it now.
    func holdOrRelease(_ chunk: Data) -> Bool {
        lock.withLock {
            guard holding else { return true }
            chunks.append(chunk)
            return false
        }
    }

    /// Stops holding and hands back what was held, for the caller to release.
    func stopHolding() -> [Data] {
        lock.withLock {
            holding = false
            defer { chunks = [] }
            return chunks
        }
    }
}
