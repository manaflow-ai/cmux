public import CmuxNextSettings
import Foundation

/// The control half of `debug.native_transcript` (the App registers it in Debug and bench builds): drives the
/// native transcript window (RFD 0121, app-perf.md section 6, first PR; read-only, the 3,000-row fixture, never on
/// by default) for `scripts/ci/frame-pacing/transcript_fling.py`.
///
/// `action`:
/// - `open` {`width`, `height`: points, default 900 x 1000}: opens the window, waits for its render thread's
///   renderer and returns `open`, `renderer` (false: no GPU or the scene refused), `rows` and the stats.
/// - `fling` {`velocity`: points per second, default -3000 (toward the top; positive scrolls toward the end),
///   `wait`: seconds to wait before answering, default 0}: starts a fling; with `wait`, answers with the stats after.
/// - `scroll_to` {`offset`: points from the top}.
/// - `stats`: the scene's `CmuxNtStats` fields (`frames`, `late_texture_frames`, `late_textures`,
///   `interval_p50_ms`/`p95`/`max`, `build_p50_us`/`p95`/`max`, `intervals_over_8_33`) and this host's own
///   (`presented_*`: intervals of what reached the glass while flinging, `skipped_frames`, `quads_max`,
///   `glyphs_rasterized`, `textures_made`, `textures_evicted`, `refresh_ms`, `offset`, `content_height`,
///   `flinging`, `first_row`, `last_row`).
/// - `stats_reset`: zeroes both records.
/// - `close`: closes the window; the render thread frees the scene.
///
/// A build whose app FFI has no `CCmuxNativeTranscriptFFI` module answers every action with an `error`.
/// AppServices constructs one and owns it; it owns the one open window.
@MainActor
public final class NativeTranscriptControl {
    public typealias JSON = CmuxNextSettings.JSONValue
    #if canImport(CCmuxNativeTranscriptFFI)
    private var shown: NativeTranscriptWindow?
    #endif

    public init() {}

    /// Opens the window at launch when `CMUX_NATIVE_TRANSCRIPT=1`; nothing otherwise, and nothing in a build
    /// without the module. The React transcript stays every chat's transcript.
    public func openIfAsked() {
        #if canImport(CCmuxNativeTranscriptFFI)
        guard NativeTranscriptWindow.askedByEnvironment else { return }
        show(size: CGSize(width: 900, height: 1000)) { _ in }
        #endif
    }

    #if canImport(CCmuxNativeTranscriptFFI)
    private func show(size: CGSize, then: @escaping (NativeTranscriptRenderer?) -> Void) {
        let window = shown ?? NativeTranscriptWindow(size: size)
        if shown == nil {
            shown = window
            window.onClose = { [weak self, weak window] in if let self, self.shown === window { self.shown = nil } }
        }
        window.show(size: size, then: then)
    }

    public func handle(_ params: [String: JSON]) async -> JSON {
        let action = params["action"]?.stringValue ?? "stats"
        if action == "open" { return await open(params) }
        if action == "close" {
            shown?.close()
            shown = nil
            return .object(["closed": .bool(true)])
        }
        guard let renderer = shown?.view.renderer else {
            return .object(["error": .string("the native transcript is not open; send open first")])
        }
        switch action {
        case "fling":
            let velocity = params["velocity"]?.doubleValue ?? -3000
            renderer.post { $0.fling(velocity: velocity) }
            let wait = min(max(params["wait"]?.doubleValue ?? 0, 0), 50)
            guard wait > 0 else { return .object(["flinging": .bool(true), "velocity": .number(velocity)]) }
            // wakeup-allow: the bench asked for a fixed-length fling; one bounded await in a debug RPC, never idle.
            try? await Task.sleep(for: .seconds(wait))
            return await stats(renderer)
        case "scroll_to":
            let offset = params["offset"]?.doubleValue ?? 0
            renderer.post { $0.scroll(to: offset) }
            return .object(["offset": .number(offset)])
        case "stats":
            return await stats(renderer)
        case "stats_reset":
            renderer.post { $0.resetStats() }
            return .object(["reset": .bool(true)])
        default:
            return .object(["error": .string("unknown action; use open, fling, scroll_to, stats, stats_reset or close")])
        }
    }

    private func open(_ params: [String: JSON]) async -> JSON {
        let size = CGSize(width: params["width"]?.doubleValue ?? 900, height: params["height"]?.doubleValue ?? 1000)
        let renderer = await withCheckedContinuation { (done: CheckedContinuation<NativeTranscriptRenderer?, Never>) in
            show(size: size) { done.resume(returning: $0) }
        }
        var out: [String: JSON] = ["open": .bool(true), "renderer": .bool(renderer != nil),
                                   "rows": .number(Double(NativeTranscriptRenderer.rows))]
        if let renderer, case .object(let fields) = await stats(renderer) { out.merge(fields) { current, _ in current } }
        return .object(out)
    }

    /// The renderer's stats, read on its render thread at its next tick.
    private func stats(_ renderer: NativeTranscriptRenderer) async -> JSON {
        let fields = await withCheckedContinuation { (done: CheckedContinuation<[String: Double], Never>) in
            renderer.post { done.resume(returning: $0.stats()) }
        }
        return .object(fields.mapValues { .number($0) })
    }
    #else
    public func handle(_ params: [String: JSON]) async -> JSON {
        .object(["error": .string("native transcript not in this build's app FFI (no CCmuxNativeTranscriptFFI module)")])
    }
    #endif
}
