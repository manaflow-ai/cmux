import Foundation
import CmuxNextWakeups
import GhosttyNextKit

/// Per-surface userdata handed to Ghostty as both `userdata` and
/// `io_write_userdata` (ghostty.h:607, :629).
///
/// Retained for the surface's lifetime and released only after
/// `ghostty_surface_free` returns, because free joins the IO thread that may
/// still be inside `io_write_cb`.
///
/// Checked Sendable: Ghostty's IO thread reads only the immutable `input` and
/// `linkFilter`; everything mutable is main-actor isolated.
nonisolated final class SurfaceBridge: Sendable {
    let input: TerminalInputSink
    /// Main-actor only. Weak so a late callback after the view deinitializes
    /// is a no-op.
    @MainActor weak var view: TerminalSurfaceView?
    /// The font scale after each font size change (nil: the configured
    /// size), `TerminalFontScale.observe`.
    @MainActor var onFontScaleChange: (@MainActor @Sendable (Double?) -> Void)?
    /// The last font scale Ghostty reported, nil at the configured size.
    @MainActor var fontScale: Double?
    /// True once Ghostty reported any font size change (a zoom, a reset or a set).
    @MainActor var fontScaleChanged = false

    /// The cached answers to Ghostty's link filter (cx-do47.1).
    let linkFilter = TerminalLinkFilter()
    /// What the Ghostty trace hook marks for this surface's frames (``GhosttyTraceHook``).
    let frames: GhosttyTraceHook.Surface
    /// The hook ``frames`` are registered with and the surface's trace id; nil while not registered.
    @MainActor private var traceRegistration: (hook: GhosttyTraceHook, id: UInt64)?

    init(input: TerminalInputSink, echoStage: TerminalEchoStage? = nil) {
        self.input = input
        frames = GhosttyTraceHook.Surface(key: input.typingSurface, echoStage: echoStage)
        // An answer that changed shows at once: the pointer goes to Ghostty again.
        linkFilter.onChange { [weak self] in
            MainDelivery().run { self?.sendPointerAgain() }
        }
    }

    /// Registers ``frames`` with `hook` under `surface`'s trace id, right after `ghostty_surface_new`.
    @MainActor func traceFrames(of surface: ghostty_surface_t, with hook: GhosttyTraceHook?) {
        guard let hook else { return }
        let id = hook.register(frames, of: surface)
        if id != 0 { traceRegistration = (hook, id) }
    }

    /// After `ghostty_surface_free` returned and before this bridge's release: the hook stops reading the
    /// surface's calls while ``frames`` is still alive.
    @MainActor func surfaceFreed() {
        guard let traceRegistration else { return }
        traceRegistration.hook.unregister(id: traceRegistration.id)
        self.traceRegistration = nil
    }

    /// The session's surfaces to the typing probe (``TypingLatencyProbe``): the key router opens a press
    /// on it, and Ghostty's writes, the output lane and the frame mark by it.
    var typingSurface: TypingLatencyProbe.SurfaceKey { input.typingSurface }

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

/// `io_write_cb`: runs on Ghostty's IO thread. Copies the bytes and hands them
/// to the session's ordered writer.
nonisolated func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ length: UInt) {
    guard let bridge = SurfaceBridge.from(userdata), let bytes, length > 0 else { return }
    TypingLatencyProbe.shared.inputWritten(on: bridge.input.typingSurface)
    bridge.input.send(Data(bytes: bytes, count: Int(length)))
}
