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
    /// The last font scale Ghostty reported, nil at the configured size.
    @MainActor var fontScale: Double?
    /// True once Ghostty reported any font size change (a zoom, a reset or a set).
    @MainActor var fontScaleChanged = false

    /// The cached answers to Ghostty's link filter (cx-do47.1).
    let linkFilter = TerminalLinkFilter()

    init(input: TerminalInputSink) {
        self.input = input
        // An answer that changed shows at once: the pointer goes to Ghostty again.
        linkFilter.onChange { [weak self] in
            MainDelivery().run { self?.sendPointerAgain() }
        }
    }

    /// The session's surfaces to the typing probe (``TypingLatencyProbe``): the key router opens a press
    /// on it, and Ghostty's writes, the output lane and the frame mark by it.
    var typingSurface: TypingLatencyProbe.SurfaceKey { input.typingSurface }

    /// Ghostty wrote `bytes` (`io_write_cb`, on the thread that made the write): one on the main thread
    /// (a key, a paste, a report) reaches the session's echo predictions (``PredictiveEchoSlot/written(_:by:)``).
    func wrote(_ bytes: Data) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            guard let view else { return }
            input.predictions.written(bytes, by: view)
        }
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
    /// Take over from the "Sized for" chip.
    case takeOverSize(setLatest: Bool)
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
    /// The session's surfaces to the typing probe (``TypingLatencyProbe``): the same across a surface
    /// swap, like the input order.
    let typingSurface: TypingLatencyProbe.SurfaceKey
    /// The session's echo predictions, shared by its surfaces like the input order (``PredictiveEchoSlot``).
    let predictions = PredictiveEchoSlot()

    init(continuation: AsyncStream<TerminalOutgoing>.Continuation, typingSurface: TypingLatencyProbe.SurfaceKey) {
        self.continuation = continuation
        self.typingSurface = typingSurface
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

    func takeOverSize(setLatest: Bool) {
        continuation.yield(.takeOverSize(setLatest: setLatest))
    }

    func finish() {
        continuation.finish()
    }
}

/// `io_write_cb`: runs on the thread that made the write (the main thread for keys and pastes, which
/// Ghostty's manual backend writes inline; its IO thread otherwise). Copies the bytes and hands them
/// to the session's ordered writer.
nonisolated func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ length: UInt) {
    guard let bridge = SurfaceBridge.from(userdata), let bytes, length > 0 else { return }
    TypingLatencyProbe.shared.inputWritten(on: bridge.input.typingSurface)
    let data = Data(bytes: bytes, count: Int(length))
    bridge.wrote(data)
    bridge.input.send(data)
}
