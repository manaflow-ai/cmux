import Foundation
import GhosttyKit

/// Serial, non-main lane for every call that must be serialized with
/// `ghostty_surface_process_output` (ghostty.h:1373-1380, :1589):
/// output, Kitty replay restore, theme updates.
///
/// `process_output` takes the renderer-state mutex synchronously, so it runs
/// off the main thread (cmux-tui-contract.md 3.2). ``close()`` fences the lane
/// before `ghostty_surface_free`; work queued after the fence is dropped.
nonisolated final class TerminalOutputLane: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private var surface: ghostty_surface_t?

    init(surface: ghostty_surface_t, label: String) {
        self.surface = surface
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    func processOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard let surface else { return }
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_process_output(surface, base, UInt(buffer.count))
            }
        }
    }

    /// Runs `body` on the lane with the live surface, or not at all after
    /// ``close()``.
    func perform(_ body: @escaping @Sendable (ghostty_surface_t) -> Void) {
        queue.async { [self] in
            guard let surface else { return }
            body(surface)
        }
    }

    /// Blocks until every chunk queued so far has been parsed. The main
    /// actor calls this before a call that must observe the parsed state
    /// but is not lane-safe (`ghostty_surface_set_grid_size` resizes through
    /// the apprt, which runs on the main thread).
    func drain() {
        queue.sync {}
    }

    /// Waits for queued work, then drops the surface so nothing else touches
    /// it. Call on the main actor immediately before `ghostty_surface_free`.
    func close() {
        queue.sync { surface = nil }
    }
}
