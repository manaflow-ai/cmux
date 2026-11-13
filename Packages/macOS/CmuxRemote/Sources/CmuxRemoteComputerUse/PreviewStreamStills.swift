// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension PreviewStreamSession {
    /// One JPEG of the window, at most twice a second and one at a time: the fallback when no
    /// stream runs. Only the window the last look passed through the gate (``window``), never one
    /// looked up here. The capture runs in its own task, never on `writes`, so a slow
    /// ScreenCaptureKit holds neither the channel's writes nor its close; its result is sent only
    /// if it still may be when it comes.
    func sendStill() {
        guard let id = window, stream == nil, !stillInFlight, !ended else { return }
        let now = Date()
        if let stillAt, now.timeIntervalSince(stillAt) < timing.still { return }
        stillAt = now
        stillInFlight = true
        let side = longSide, capture = capture, isEnded = isEnded
        // task-owner: the session's one still in flight (stillInFlight); its result comes back on `queue`.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<(jpeg: Data, width: Int, height: Int), ComputerUsePreview.Refusal>?
                = isEnded.withLock({ $0 }) ? nil : await capture.still(id, side)
            guard let self else { return }
            queue.async {
                // A deny-list edit, another window or a stream since the capture began: not sent.
                guard case .success(let frame)? = result, self.stillMaySend(window: id) else {
                    self.stillInFlight = false
                    return
                }
                // The status names the window's generation (as `streaming` does) once per window,
                // so the app drops another window's picture before this one's still shows.
                let generation = self.streamGeneration(id)
                if self.lastState != "still" || self.lastStillGeneration != generation {
                    self.lastStillGeneration = generation
                    self.send(state: "still", extra: ["window": generation])
                }
                self.write(PreviewStreamWire.message(PreviewStreamWire.still, frame.jpeg))
                // The next still waits until this one is written: a slow app never queues stills.
                self.writes.async { [weak self] in self?.queue.async { self?.stillInFlight = false } }
            }
        }
    }

    /// Whether a still of window `id`, captured a moment ago, may go to the app now (queue).
    func stillMaySend(window id: UInt32) -> Bool {
        guard !ended, stream == nil, window == id, let owner, let app = owner.id, !app.isEmpty else { return false }
        return !blocked(app, owner.name ?? app)
    }
}
