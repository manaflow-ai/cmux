import Foundation
import Testing

/// Speed triage only (a measurement branch, never landed): prints how long each phase of a
/// live fixture takes, per test, as `phase-timing LABEL TEST PHASE SECONDS` on stderr.
nonisolated struct PhaseTimer: Sendable {
    let label: String
    let start: ContinuousClock.Instant

    init(_ label: String) {
        self.label = label
        start = ContinuousClock.now
    }

    func mark(_ phase: String) {
        let elapsed = start.duration(to: ContinuousClock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let line = "phase-timing \(label) \(Test.current?.name ?? "?") \(phase) \((seconds * 1000).rounded() / 1000)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Marks `phase` once `condition` holds (polled every 50 ms, up to 200 s); cancel the task at teardown.
    @MainActor func watch(_ phase: String, _ condition: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(200)
            while !condition(), ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            if condition() { mark(phase) }
        }
    }
}

/// Speed triage only: prints each main-queue stall over 500 ms while it runs, as
/// `phase-timing stall LABEL TEST main-blocked-ms N at-s T` (a thread pings the main queue every 100 ms).
nonisolated final class MainStallWatch: @unchecked Sendable { // the flag is read and written under `lock`
    private let lock = NSLock()
    private var running = true

    init(_ label: String) {
        let test = Test.current?.name ?? "?"
        let start = DispatchTime.now()
        Thread.detachNewThread { [self] in
            while isRunning {
                let sent = DispatchTime.now()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let blocked = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e6
                if blocked > 500 {
                    let at = Double(sent.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                    FileHandle.standardError.write(Data("phase-timing stall \(label) \(test) main-blocked-ms \(Int(blocked)) at-s \((at * 10).rounded() / 10)\n".utf8))
                }
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(100))
            }
        }
    }

    private var isRunning: Bool { lock.withLock { running } }

    func stop() { lock.withLock { running = false } }
}
