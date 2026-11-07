import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import ScreenCaptureKit

/// The recording following its window, and the deadline on each ScreenCaptureKit call (a
/// disconnected replayd never answers).
extension AgentPaneRecording {
    /// The window moved or resized (`frame`: its frame in global top-left points): the stream
    /// follows it. Updates run one at a time off the main actor, each with the newest frame, so a
    /// live resize costs one ScreenCaptureKit call in flight, never one per notice.
    nonisolated func follow(_ frame: CGRect) {
        let run = state.withLock { state -> Bool in
            guard !state.ending else { return false }
            state.moved = frame
            defer { state.updating = true }
            return !state.updating
        }
        guard run else { return }
        Task.detached(priority: .userInitiated) { [self] in
            while let next = state.withLock({ state -> (frame: CGRect, display: CGRect)? in
                guard let frame = state.moved, let display = state.display, !state.ending else { state.updating = false; return nil }
                state.moved = nil
                return (frame, display)
            }) {
                guard let source = Self.source(next.frame, on: next.display),
                      let handed = streamSlot.withLock({ $0 }) else { continue }
                let configuration = configuration(source)
                _ = try? await deadline("update the capture") { (done: @escaping @Sendable (Result<Bool, any Error>) -> Void) in
                    handed.value.updateConfiguration(configuration) { error in done(error.map { .failure($0) } ?? .success(true)) }
                }
            }
        }
    }

    /// The window's part of the display, in the display's points from its top-left; nil when none.
    nonisolated static func source(_ window: CGRect, on display: CGRect) -> CGRect? {
        let source = window.intersection(display).offsetBy(dx: -display.minX, dy: -display.minY)
        return source.width >= 1 && source.height >= 1 ? source : nil
    }

    /// Runs `call` and returns its result, or throws after ``callLimit``; a late callback is dropped.
    nonisolated func deadline<T: Sendable>(_ what: String, _ call: (@escaping @Sendable (Result<T, any Error>) -> Void) -> Void) async throws -> T {
        let once = AgentPaneRecordingOnce<T>()
        let timer = DemandTimer(owner: "agent-pane.capture.record.deadline")
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            once.set(continuation)
            call { once.resume($0) }
            timer.schedule(after: Self.callLimit) {
                once.resume(.failure(Failure(description: "ScreenCaptureKit did not \(what) within \(Self.callLimit)")))
            }
        }
    }
}

/// Resumes a continuation once; later results are dropped.
nonisolated final class AgentPaneRecordingOnce<T: Sendable>: Sendable {
    // concurrency-allow: held only to take or set the continuation; resuming it happens after the unlock.
    private let slot = Mutex<CheckedContinuation<T, any Error>?>(nil)
    func set(_ continuation: CheckedContinuation<T, any Error>) { slot.withLock { $0 = continuation } }
    func resume(_ result: Result<T, any Error>) {
        let pending = slot.withLock { slot -> CheckedContinuation<T, any Error>? in
            defer { slot = nil }
            return slot
        }
        pending?.resume(with: result)
    }
}
