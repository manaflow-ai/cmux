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
