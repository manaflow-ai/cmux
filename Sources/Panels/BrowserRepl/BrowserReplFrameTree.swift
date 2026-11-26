import AppKit
import CmuxBrowser
import WebKit

/// Reads a web view's frame tree.
///
/// WebKit has no public frame enumeration. `-[WKWebView _frames:]` (macOS 11+)
/// returns the tree with a `WKFrameInfo` per frame, which is what
/// `callAsyncJavaScript(_:arguments:in:in:)` needs to reach a cross-origin
/// frame. When the selector is missing, only the main frame is reported.
///
/// `_frames:` asks every web process that hosts a frame of the page, so it
/// costs about 5 ms on a page of 400 frames and a burst of reads queues
/// behind each other (400 frame calls in flight, each reading the tree,
/// took seconds to minutes). Reads go through one ``BrowserReplFrameRegistry``
/// per web view: a frame call looks its frame up by id without a read, and
/// callers that need the tree as it is now share one fresh read.
@MainActor
enum BrowserReplFrameTree {
    private static let registries = NSMapTable<WKWebView, FrameRegistryBox>.weakToStrongObjects()

    private final class FrameRegistryBox {
        let registry: BrowserReplFrameRegistry<BrowserReplFrame>
        init(_ registry: BrowserReplFrameRegistry<BrowserReplFrame>) { self.registry = registry }
    }

    private static func registry(for webView: WKWebView) -> BrowserReplFrameRegistry<BrowserReplFrame> {
        if let box = registries.object(forKey: webView) { return box.registry }
        let registry = BrowserReplFrameRegistry<BrowserReplFrame>(
            id: { $0.frameID },
            read: { [weak webView] in
                guard let webView else { return [] }
                return await readFrames(of: webView)
            }
        )
        registries.setObject(FrameRegistryBox(registry), forKey: webView)
        return registry
    }

    /// The frame tree as it is now: a read that starts after this call,
    /// shared with other callers waiting at the same time.
    static func frames(of webView: WKWebView) async -> [BrowserReplFrame] {
        await registry(for: webView).frames(refresh: true)
    }

    private static func readFrames(of webView: WKWebView) async -> [BrowserReplFrame] {
        await BrowserReplFrame.readTree(of: webView)
    }

    /// The frame with `frameID`, or the main frame for `nil`. Frame ids are
    /// stable for a frame's life, so a known id needs no tree read; an
    /// unknown one reads the tree once.
    static func frame(_ frameID: String?, in webView: WKWebView) async -> BrowserReplFrame? {
        let registry = registry(for: webView)
        guard let frameID, !frameID.isEmpty else { return await registry.frames().first }
        return await registry.frame(frameID)
    }

    /// WebKit's stable per-frame id (`WKFrameInfo._handle.frameID`).
    static func frameID(of info: WKFrameInfo) -> String? {
        BrowserReplFrame.frameID(of: info)
    }
}
