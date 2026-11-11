import AppKit
import CmuxNextWakeups

/// A drop's file promises, written by their source into a folder of their own (the screenshot
/// thumbnail, Photos, a browser's or Preview's picture: the drag carries a promise, not a file).
///
/// The drop asks the sources at once, in the drop's own turn (AppKit's rule), and their files
/// arrive on a background queue: the main thread never waits for a source. A source that never
/// writes (it quit, it failed) ends at `timeout` (a DemandTimer on the injected clock). The files keep the
/// drop's order; `discard()` removes the folder once the composer copied them (the blob cache
/// holds its own copy).
final class HomePromisedFiles {
    /// How long a drop waits for its sources before it gives up on the missing files.
    static let timeout: Duration = .seconds(30)

    let folder: URL
    /// The files, in the drop's order; empty when no source wrote one.
    let files: Task<[URL], Never>
    /// How many files the sources promised.
    let expected: Int
    /// Ends the wait at `timeout` when a source never writes.
    private let deadline: DemandTimer
    /// Kept until the files came: the receivers and the queue their answers arrive on.
    private let receivers: [any HomeFilePromise]
    private let queue: OperationQueue

    /// Asks every receiver for its files now. Nil when there is no promise or the folder can't be made.
    init?(_ receivers: [any HomeFilePromise], timeout: Duration = HomePromisedFiles.timeout,
          clock: any Clock<Duration> = ContinuousClock()) {
        guard !receivers.isEmpty else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-home-drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        self.folder = folder
        // A legacy promise may stand for several files (one type each); a modern one is one file.
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        self.expected = expected
        self.receivers = receivers
        // Each source answers once per file: the buffer holds every answer the drop can get.
        let (arrivals, sink) = AsyncStream.makeStream(of: Arrival.self, bufferingPolicy: .bufferingOldest(expected))
        let queue = OperationQueue()
        queue.name = "cmux.home.promised-files"
        queue.qualityOfService = .userInitiated
        self.queue = queue
        for (index, receiver) in receivers.enumerated() {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { @Sendable url, error in
                sink.yield(Arrival(index: index, url: error == nil ? url : nil))
            }
        }
        let deadline = DemandTimer(owner: "home.promisedFiles", clock: clock)
        deadline.schedule(after: timeout) { sink.finish() }
        self.deadline = deadline
        // task-owner: ends when every file came or at the deadline (`sink.finish()`)
        files = Task {
            var got: [Arrival] = []
            for await arrival in arrivals {
                got.append(arrival)
                if got.count >= expected { break }
            }
            deadline.cancel()
            sink.finish()
            // Stable: the files of one receiver keep their arrival order.
            return got.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
                .compactMap(\.element.url)
        }
    }

    /// Removes the folder and what is left in it.
    func discard() {
        try? FileManager.default.removeItem(at: folder)
    }

    nonisolated private struct Arrival: Sendable {
        let index: Int
        let url: URL?
    }
}
