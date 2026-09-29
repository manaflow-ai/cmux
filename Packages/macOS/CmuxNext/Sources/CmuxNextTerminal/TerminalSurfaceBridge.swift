import Foundation
import GhosttyKit

/// Per-surface userdata handed to Ghostty as both `userdata` and
/// `io_write_userdata` (ghostty.h:607, :629).
///
/// Retained for the surface's lifetime and released only after
/// `ghostty_surface_free` returns, because free joins the IO thread that may
/// still be inside `io_write_cb`.
nonisolated final class SurfaceBridge: @unchecked Sendable {
    let input: TerminalInputSink
    /// Main-actor only. Weak so a late callback after the view deinitializes
    /// is a no-op.
    @MainActor weak var view: TerminalSurfaceView?

    init(input: TerminalInputSink) {
        self.input = input
    }

    static func from(_ raw: UnsafeMutableRawPointer?) -> SurfaceBridge? {
        guard let raw else { return nil }
        return Unmanaged<SurfaceBridge>.fromOpaque(raw).takeUnretainedValue()
    }
}

/// Everything a session sends to its ``TerminalIO``, in one ordered stream
/// so a resize never overtakes input typed before it.
nonisolated enum TerminalOutgoing: Sendable {
    case bytes(Data)
    case resize(TerminalGridSize, pixelWidth: Int, pixelHeight: Int)
}

/// Ordered hand-off from Ghostty's IO thread to the async `TerminalIO.write`.
/// One continuation per session, shared by every surface the session swaps
/// in, so input order survives a surface swap.
nonisolated struct TerminalInputSink: Sendable {
    private let continuation: AsyncStream<TerminalOutgoing>.Continuation

    init(continuation: AsyncStream<TerminalOutgoing>.Continuation) {
        self.continuation = continuation
    }

    func send(_ data: Data) {
        continuation.yield(.bytes(data))
    }

    func resize(_ grid: TerminalGridSize, pixelWidth: Int, pixelHeight: Int) {
        continuation.yield(.resize(grid, pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }

    func finish() {
        continuation.finish()
    }
}

/// `io_write_cb`: runs on Ghostty's IO thread. Copies the bytes and hands them
/// to the session's ordered writer.
nonisolated func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ length: UInt) {
    guard let bridge = SurfaceBridge.from(userdata), let bytes, length > 0 else { return }
    bridge.input.send(Data(bytes: bytes, count: Int(length)))
}

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

    /// Waits for queued work, then drops the surface so nothing else touches
    /// it. Call on the main actor immediately before `ghostty_surface_free`.
    func close() {
        queue.sync { surface = nil }
    }
}
