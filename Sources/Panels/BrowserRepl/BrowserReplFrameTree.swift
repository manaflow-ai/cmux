import AppKit
import CmuxBrowser
import WebKit

/// One frame of a tab, in document order, as the REPL driver reports it.
struct BrowserReplFrame {
    let frameID: String
    let parentFrameID: String?
    /// Position among the parent's child frames (`window.frames[index]`).
    let indexInParent: Int
    /// Frame info for WebKit evaluation APIs; `nil` means the main frame.
    let info: WKFrameInfo?
    let url: String
    let name: String
    let crossOrigin: Bool
}

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
        let selector = NSSelectorFromString("_frames:")
        guard webView.responds(to: selector) else {
            return [mainFrameFallback(webView)]
        }
        let root: AnyObject? = await withCheckedContinuation { continuation in
            typealias Completion = @convention(block) (AnyObject?) -> Void
            typealias FramesFunction = @convention(c) (AnyObject, Selector, Completion) -> Void
            let function = unsafeBitCast(webView.method(for: selector), to: FramesFunction.self)
            let completion: Completion = { node in
                continuation.resume(returning: node)
            }
            function(webView, selector, completion)
        }
        guard let root, let rootInfo = frameInfo(of: root) else {
            return [mainFrameFallback(webView)]
        }
        let mainOrigin = originKey(rootInfo.securityOrigin)
        var result: [BrowserReplFrame] = []
        func walk(_ node: AnyObject, parentID: String?, index: Int) {
            guard let info = frameInfo(of: node) else { return }
            let id = frameID(of: info) ?? (parentID.map { "\($0).\(index)" } ?? "main")
            result.append(BrowserReplFrame(
                frameID: id,
                parentFrameID: parentID,
                indexInParent: index,
                info: info,
                url: info.request.url?.absoluteString ?? "",
                name: "",
                crossOrigin: originKey(info.securityOrigin) != mainOrigin
            ))
            let children: [AnyObject]
            if let object = node as? NSObject, object.responds(to: NSSelectorFromString("childFrames")) {
                children = (object.value(forKey: "childFrames") as? [AnyObject]) ?? []
            } else {
                children = []
            }
            for (childIndex, child) in children.enumerated() {
                walk(child, parentID: id, index: childIndex)
            }
        }
        walk(root, parentID: nil, index: 0)
        return result
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
        let handleSelector = NSSelectorFromString("_handle")
        guard info.responds(to: handleSelector),
              let handle = info.perform(handleSelector)?.takeUnretainedValue() as? NSObject,
              handle.responds(to: NSSelectorFromString("frameID")),
              let number = handle.value(forKey: "frameID") as? NSNumber else {
            return nil
        }
        return number.stringValue
    }

    private static func frameInfo(of node: AnyObject) -> WKFrameInfo? {
        if let info = node as? WKFrameInfo { return info }
        guard let object = node as? NSObject, object.responds(to: NSSelectorFromString("info")) else {
            return nil
        }
        return object.value(forKey: "info") as? WKFrameInfo
    }

    private static func originKey(_ origin: WKSecurityOrigin) -> String {
        "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    private static func mainFrameFallback(_ webView: WKWebView) -> BrowserReplFrame {
        BrowserReplFrame(
            frameID: "main",
            parentFrameID: nil,
            indexInParent: 0,
            info: nil,
            url: webView.url?.absoluteString ?? "",
            name: "",
            crossOrigin: false
        )
    }
}
