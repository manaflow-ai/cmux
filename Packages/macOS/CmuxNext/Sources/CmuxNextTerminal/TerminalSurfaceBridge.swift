import Foundation
import CmuxNextWakeups
import GhosttyNextKit

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
    /// The font scale after each font size change (nil: the configured
    /// size), `TerminalFontScale.observe`.
    @MainActor var onFontScaleChange: ((Double?) -> Void)?

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
    case focusGained
    /// The user clicked a disconnected terminal: re-attach.
    case reconnect
    /// The mirror needs a full snapshot from the owner.
    case resync
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

    func reconnect() {
        continuation.yield(.reconnect)
    }

    func resync() {
        continuation.yield(.resync)
    }

    func focusGained() {
        continuation.yield(.focusGained)
    }

    func finish() {
        continuation.finish()
    }
}

/// `io_write_cb`: runs on Ghostty's IO thread. Copies the bytes and hands them
/// to the session's ordered writer.
nonisolated func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ length: UInt) {
    guard let bridge = SurfaceBridge.from(userdata), let bytes, length > 0 else { return }
    TypingLatencyProbe.shared.mark(.ioWrite)
    bridge.input.send(Data(bytes: bytes, count: Int(length)))
}
