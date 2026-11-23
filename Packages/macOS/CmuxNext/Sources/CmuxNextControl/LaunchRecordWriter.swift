public import CmuxNextWakeups
public import Foundation
import os

/// One app-owned writer. Debounce only takes the snapshot; Rust encodes and
/// atomically replaces the file on BackgroundWork's files lane.
@MainActor
public final class LaunchRecordWriter {
    private let url: URL
    private let work: BackgroundWork
    private let snapshot: @MainActor () async -> LaunchRecordSnapshot?
    private let write: @Sendable (LaunchRecordSnapshot, URL) -> Bool
    private let timer: DemandTimer
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "launch-record")
    private var requested = false
    private var drain: Task<Void, Never>?

    public init(url: URL, work: BackgroundWork,
                clock: any Clock<Duration> = ContinuousClock(),
                write: @escaping @Sendable (LaunchRecordSnapshot, URL) -> Bool = LaunchRecordEncoding.write,
                snapshot: @escaping @MainActor () async -> LaunchRecordSnapshot?) {
        self.url = url; self.work = work; self.snapshot = snapshot; self.write = write
        timer = DemandTimer(owner: "launch-record.write", clock: clock)
    }

    public func schedule() {
        timer.schedule(after: .milliseconds(500)) { @MainActor [weak self] in self?.request() }
    }

    /// The quit path awaits this before hiding windows or stopping engines.
    /// A write already in flight finishes first; it cannot overwrite this final snapshot.
    public func flush() async {
        timer.cancel()
        request()
        await drain?.value
    }

    private func request() {
        requested = true
        guard drain == nil else { return }
        // task-owner: drain; flush awaits it at quit, and it releases itself after the last write.
        drain = Task { [self] in
            while requested {
                requested = false
                guard let value = await snapshot() else { continue }
                let write = write, url = url
                do {
                    let written = try await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
                        write(value, url)
                    }
                    if !written { logger.error("launch record write failed") }
                } catch {
                    logger.error("launch record write skipped: \(String(describing: error), privacy: .public)")
                }
            }
            drain = nil
        }
    }
}
