package import CoreGraphics

/// The intent prewarm's kinds beside the wake itself, for the hibernated targets it holds:
/// - the cover: the page's last frame decoded off the main thread before its restore starts, so the restored
///   page's cover shows it from its first frame (`BrowserWakeStandIn`, `decoded: true`) instead of decoding it
///   (10 to 30 ms for a full page) once the switch puts the page in a window;
/// - the geometry: the size the page shows at, so the restored page lays out hidden at its final size, not
///   on the switch's frame. Chrome sizes a prerendered page to the initiator tab's view before activation
///   (content/browser/preloading/prerender/prerender_host.cc).
/// A cancel (evicted, critical pressure) drops both and makes a running decode's reply stale; the restore
/// takes them. The app's `BrowserHibernation` owns one.
package struct IntentPrewarmKinds {
    /// Draws a page picture into a bitmap off the main thread and hands it back on the main thread; the
    /// composition root passes the app's `.cpu` lane with a background-class reply. Nil: no cover decode.
    package var decodeCover: (@MainActor (CGImage, @escaping @MainActor @Sendable (CGImage) -> Void) -> Void)?
    /// The cover decode each target waits for, by tab: its ticket. A reply whose ticket is gone is stale.
    package private(set) var decodes: [String: UInt64] = [:]
    /// Covers decoded ahead of a restore, by tab.
    package private(set) var covers: [String: CGImage] = [:]
    /// The size each target shows at, from its prewarm.
    package private(set) var sizes: [String: CGSize] = [:]
    /// The size each hibernated page's view had when it slept: its target size when no pane lists it.
    package private(set) var sleptSizes: [String: CGSize] = [:]
    private var lastTicket: UInt64 = 0

    package init() {}

    /// `key`'s cover decode starts; returns the ticket its reply must bring back.
    package mutating func beginDecode(_ key: String) -> UInt64 {
        lastTicket &+= 1
        decodes[key] = lastTicket
        return lastTicket
    }

    /// The decode with `ticket` landed: true, and `cover` is kept, when it is still the one `key` waits for.
    package mutating func decoded(_ key: String, _ cover: CGImage, ticket: UInt64) -> Bool {
        guard decodes[key] == ticket else { return false }
        decodes[key] = nil
        covers[key] = cover
        return true
    }

    /// `key`'s page shows at `size` (nil: unknown).
    package mutating func target(_ key: String, size: CGSize?) {
        sizes[key] = size
    }

    /// `key`'s page is back: its restore takes the decoded cover and the size, a running decode goes stale,
    /// and its slept size goes.
    package mutating func takeForRestore(_ key: String) -> (cover: CGImage?, size: CGSize?) {
        decodes[key] = nil
        sleptSizes[key] = nil
        return (covers.removeValue(forKey: key), sizes.removeValue(forKey: key))
    }

    /// `key`'s prewarm was cancelled, or its page woke another way first.
    package mutating func cancel(_ key: String) {
        decodes[key] = nil
        covers[key] = nil
        sizes[key] = nil
    }

    /// `key`'s page hibernated with its view at `size`; any prewarm state of an earlier wake is stale.
    package mutating func slept(_ key: String, size: CGSize) {
        cancel(key)
        sleptSizes[key] = size.width > 0 && size.height > 0 ? size : nil
    }

    /// `key`'s tab closed.
    package mutating func forget(_ key: String) {
        cancel(key)
        sleptSizes[key] = nil
    }
}
