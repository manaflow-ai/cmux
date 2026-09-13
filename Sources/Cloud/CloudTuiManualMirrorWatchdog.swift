import Foundation

/// Deadlines for one native cloud attachment.
///
/// The handshake must finish within its bound, and an attached stream must
/// keep proving liveness: any inbound frame counts, and a quiet stream is
/// probed with `ping`. The watchdog only measures time; the owning session
/// decides every transition on the main actor when an expiry is reported.
@MainActor
final class CloudTuiManualMirrorWatchdog {
    private let deadlines: CloudTuiManualMirrorDeadlines
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?
    private var framesSinceCheck = 0
    private var probeAnswered = false

    init(deadlines: CloudTuiManualMirrorDeadlines, clock: any Clock<Duration>) {
        self.deadlines = deadlines
        self.clock = clock
    }

    /// Starts the handshake deadline. `onExpiry` fires once if it elapses
    /// before ``armLiveness(probe:onExpiry:)`` or ``cancel()`` replaces it.
    func armHandshake(onExpiry: @escaping @MainActor () -> Void) {
        task?.cancel()
        let deadline = deadlines.handshake
        task = Task { @MainActor [clock] in
            do {
                try await clock.sleep(for: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onExpiry()
        }
    }

    /// Starts liveness monitoring for an attached stream. After
    /// `livenessInterval` without a frame, `probe` is sent; if neither a frame
    /// nor ``noteProbeAnswered()`` arrives within `livenessAnswer`, `onExpiry`
    /// fires once and monitoring stops.
    func armLiveness(
        probe: @escaping @MainActor () -> Void,
        onExpiry: @escaping @MainActor () -> Void
    ) {
        task?.cancel()
        framesSinceCheck = 0
        probeAnswered = false
        let deadlines = deadlines
        task = Task { @MainActor [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: deadlines.livenessInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                if self.framesSinceCheck > 0 {
                    self.framesSinceCheck = 0
                    continue
                }
                self.probeAnswered = false
                probe()
                do {
                    try await clock.sleep(for: deadlines.livenessAnswer)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if self.probeAnswered || self.framesSinceCheck > 0 {
                    self.framesSinceCheck = 0
                    continue
                }
                self.task = nil
                onExpiry()
                return
            }
        }
    }

    /// Any inbound frame proves the stream is alive.
    func noteFrame() {
        framesSinceCheck += 1
    }

    func noteProbeAnswered() {
        probeAnswered = true
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
