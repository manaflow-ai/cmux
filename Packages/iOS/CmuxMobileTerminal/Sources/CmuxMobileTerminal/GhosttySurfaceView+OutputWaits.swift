#if canImport(UIKit)
import CmuxMobileTerminalKit
import UIKit

extension GhosttySurfaceView {
    /// Process terminal output and return after the output has been applied.
    ///
    /// The call still performs libghostty output processing on the serial
    /// background output queue. The returned async boundary lets callers apply
    /// per-surface backpressure without blocking the main actor while Ghostty
    /// consumes the chunk.
    /// - Parameter data: VT or PTY bytes to feed into the surface.
    public func processOutputAndWait(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            processOutput(data) {
                continuation.resume(returning: $0)
            }
        }
    }

    func registerPendingOutputCompletion(
        generation: UInt64,
        completion: (@MainActor @Sendable (Bool) -> Void)?
    ) -> TerminalSurfaceOutputWaitState.WaitID? {
        guard let completion else { return nil }
        let id = pendingOutputWaits.register(generation: generation)
        pendingOutputCompletions[generation, default: [:]][id] = completion
        return id
    }

    func completePendingOutput(
        generation: UInt64,
        id: TerminalSurfaceOutputWaitState.WaitID?,
        applied: Bool
    ) {
        guard let id,
              pendingOutputWaits.complete(generation: generation, id: id),
              let completion = pendingOutputCompletions[generation]?.removeValue(forKey: id) else {
            return
        }
        if pendingOutputCompletions[generation]?.isEmpty == true {
            pendingOutputCompletions[generation] = nil
        }
        completion(applied)
    }

    func completeAllPendingOutput(generation: UInt64) {
        for id in pendingOutputWaits.cancel(generation: generation) {
            guard let completion = pendingOutputCompletions[generation]?.removeValue(forKey: id) else {
                continue
            }
            completion(false)
        }
        if pendingOutputCompletions[generation]?.isEmpty == true {
            pendingOutputCompletions[generation] = nil
        }
    }

    func completeAllPendingOutput() {
        for wait in pendingOutputWaits.cancelAll() {
            guard let completion = pendingOutputCompletions[wait.generation]?.removeValue(forKey: wait.id) else {
                continue
            }
            completion(false)
        }
        pendingOutputCompletions.removeAll()
    }
}
#endif
