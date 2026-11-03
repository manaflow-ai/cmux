import CmuxNextDesign
import Foundation
import os

/// A launch file reader for tests (``LaunchFileReader/init(read:)``): it records whether each read of a file
/// that exists ran on the main thread, and, when made `held`, tells ``started`` and holds each read until ``release()``, so a
/// test sees what the pane shows while the read runs.
nonisolated final class LaunchReadProbe: Sendable {
    private let onMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    private let gate: DispatchSemaphore?
    private let continuation: AsyncStream<Void>.Continuation
    /// Yields once as each held read starts.
    let started: AsyncStream<Void>

    init(held: Bool = false) {
        gate = held ? DispatchSemaphore(value: 0) : nil
        (started, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// Whether each read so far ran on the main thread, in order.
    var reads: [Bool] { onMain.withLock { $0 } }

    /// Reads the files on disk through this probe.
    var reader: LaunchFileReader {
        LaunchFileReader { [self] url, maximumBytes in
            // A name tried that holds no file is no read.
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            onMain.withLock { $0.append(Thread.isMainThread) }
            if let gate {
                continuation.yield()
                gate.wait()
            }
            guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
            return data
        }
    }

    /// Whether a held read started within 10 s (false: none did, so nothing waits on the gate).
    func waitForStart() async -> Bool {
        let started = started
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in started { return true }
                return false
            }
            group.addTask {
                // A deadline, so a read that never starts fails the test instead of hanging the run.
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Lets one held read go on.
    func release() {
        gate?.signal()
    }
}
