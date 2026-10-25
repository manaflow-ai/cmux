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

    /// Lets one held read go on.
    func release() {
        gate?.signal()
    }
}
