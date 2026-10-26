import CoreGraphics

/// The intent prewarm's kinds beside the wake itself (p04-input-042), for the hibernated targets it holds:
/// - the cover: the page's last frame decoded off the main thread before its restore starts, so the restored
///   page's cover shows it from its first frame (`BrowserWakeStandIn`, `decoded: true`) instead of decoding it
///   (10 to 30 ms for a full page) once the switch puts the page in a window;
/// - the geometry: the size the page shows at, so the restored page lays out hidden at its final size, not
///   on the switch's frame. Chrome sizes a prerendered page to the initiator tab's view before activation
///   (content/browser/preloading/prerender/prerender_host.cc).
/// A cancel (evicted, critical pressure) drops both and stops a running decode; the restore takes them.
struct IntentPrewarmKinds {
    /// Cover decodes running off the main thread, by tab.
    private(set) var decodes: [String: Task<Void, Never>] = [:]
    /// Covers decoded ahead of a restore, by tab.
    private(set) var covers: [String: CGImage] = [:]
    /// The size each target shows at, from its prewarm.
    private(set) var sizes: [String: CGSize] = [:]
    /// The size each hibernated page's view had when it slept: its target size when no pane lists it.
    private(set) var sleptSizes: [String: CGSize] = [:]

    /// `key`'s cover decodes in `task`.
    mutating func decoding(_ key: String, _ task: Task<Void, Never>) {
        decodes[key]?.cancel()
        decodes[key] = task
    }

    /// `key`'s cover is decoded.
    mutating func decoded(_ key: String, _ cover: CGImage) {
        decodes[key] = nil
        covers[key] = cover
    }

    /// `key`'s page shows at `size` (nil: unknown).
    mutating func target(_ key: String, size: CGSize?) {
        sizes[key] = size
    }

    /// `key`'s page is back: its restore takes the decoded cover and the size, and its slept size goes.
    mutating func takeForRestore(_ key: String) -> (cover: CGImage?, size: CGSize?) {
        decodes.removeValue(forKey: key)?.cancel()
        sleptSizes[key] = nil
        return (covers.removeValue(forKey: key), sizes.removeValue(forKey: key))
    }

    /// `key`'s prewarm was cancelled, or its page woke another way first.
    mutating func cancel(_ key: String) {
        decodes.removeValue(forKey: key)?.cancel()
        covers[key] = nil
        sizes[key] = nil
    }

    /// `key`'s page hibernated with its view at `size`; any prewarm state of an earlier wake is stale.
    mutating func slept(_ key: String, size: CGSize) {
        cancel(key)
        sleptSizes[key] = size.width > 0 && size.height > 0 ? size : nil
    }

    /// `key`'s tab closed.
    mutating func forget(_ key: String) {
        cancel(key)
        sleptSizes[key] = nil
    }
}
