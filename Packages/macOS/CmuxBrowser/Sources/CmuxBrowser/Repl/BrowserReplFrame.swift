public import WebKit

/// One frame of a tab, in document order, as the REPL driver reports it.
public struct BrowserReplFrame {
    public let frameID: String
    public let parentFrameID: String?
    /// Position among the parent's child frames (`window.frames[index]`).
    public let indexInParent: Int
    /// Frame info for WebKit evaluation APIs; `nil` means the main frame.
    /// WebKit's record of the frame as it was when the tree was read: a
    /// frame that navigated since keeps its id, but this info still names
    /// the old document.
    public let info: WKFrameInfo?
    public let url: String
    /// ``url`` as a refusal or another message names the frame: as any
    /// reader but the tab's creator reads a page URL
    /// (``BrowserReplPageURL/credentialFree``). A message names a frame the
    /// session may not read, or one whose document changed under it, so
    /// not even the tab's creator gets the URL as written there.
    public var shownURL: String { BrowserReplPageURL(url, creator: nil).credentialFree }
    public let name: String
    public let crossOrigin: Bool
    /// Whether the tree read may lack some of this frame's child frames:
    /// WebKit gave no tree (only the main frame is known then), or could
    /// not describe a child. The frame gate then counts the frame's child
    /// frames in its document before it lets input or a capture through.
    public let childFramesUnread: Bool

    public init(
        frameID: String,
        parentFrameID: String?,
        indexInParent: Int,
        info: WKFrameInfo?,
        url: String,
        name: String,
        crossOrigin: Bool,
        childFramesUnread: Bool = false
    ) {
        self.frameID = frameID
        self.parentFrameID = parentFrameID
        self.indexInParent = indexInParent
        self.info = info
        self.url = url
        self.name = name
        self.crossOrigin = crossOrigin
        self.childFramesUnread = childFramesUnread
    }

    /// This frame, marked as one whose child frames the read may lack.
    func withChildFramesUnread() -> BrowserReplFrame {
        BrowserReplFrame(
            frameID: frameID,
            parentFrameID: parentFrameID,
            indexInParent: indexInParent,
            info: info,
            url: url,
            name: name,
            crossOrigin: crossOrigin,
            childFramesUnread: true
        )
    }
}

extension BrowserReplFrame {
    /// Reads `webView`'s frame tree, parents before children.
    ///
    /// WebKit has no public frame enumeration. `-[WKWebView _frames:]`
    /// (macOS 11+) returns the tree with a `WKFrameInfo` per frame, which is
    /// what `callAsyncJavaScript(_:arguments:in:in:)` needs to reach a
    /// cross-origin frame. When the selector is missing, only the main frame
    /// is reported, marked ``childFramesUnread``; so is a frame with a child
    /// WebKit could not describe, which is left out.
    @MainActor
    public static func readTree(of webView: WKWebView) async -> [BrowserReplFrame] {
        let selector = NSSelectorFromString("_frames:")
        guard webView.responds(to: selector) else {
            return [mainFrameFallback(webView)]
        }
        let reply: TreeNode = await withCheckedContinuation { continuation in
            typealias Completion = @convention(block) (AnyObject?) -> Void
            typealias FramesFunction = @convention(c) (AnyObject, Selector, Completion) -> Void
            let function = unsafeBitCast(webView.method(for: selector), to: FramesFunction.self)
            let completion: Completion = { node in
                continuation.resume(returning: TreeNode(node))
            }
            function(webView, selector, completion)
        }
        guard let root = reply.node, let rootInfo = frameInfo(of: root) else {
            return [mainFrameFallback(webView)]
        }
        let mainOrigin = originKey(rootInfo.securityOrigin)
        var result: [BrowserReplFrame] = []
        /// Returns whether the node could be described.
        @discardableResult
        func walk(_ node: AnyObject, parentID: String?, index: Int) -> Bool {
            guard let info = frameInfo(of: node) else { return false }
            let id = frameID(of: info) ?? (parentID.map { "\($0).\(index)" } ?? "main")
            let position = result.count
            result.append(BrowserReplFrame(
                frameID: id,
                parentFrameID: parentID,
                indexInParent: index,
                info: info,
                url: info.request.url?.absoluteString ?? "",
                name: "",
                crossOrigin: originKey(info.securityOrigin) != mainOrigin
            ))
            var complete = true
            let children: [AnyObject]
            if let object = node as? NSObject, object.responds(to: NSSelectorFromString("childFrames")) {
                children = (object.value(forKey: "childFrames") as? [AnyObject]) ?? []
            } else {
                children = []
                complete = false
            }
            for (childIndex, child) in children.enumerated() {
                if !walk(child, parentID: id, index: childIndex) { complete = false }
            }
            if !complete { result[position] = result[position].withChildFramesUnread() }
            return true
        }
        walk(root, parentID: nil, index: 0)
        return result
    }

    /// WebKit answers `_frames:` on the main thread, where the tree is read.
    private final class TreeNode: @unchecked Sendable {
        let node: AnyObject?
        init(_ node: AnyObject?) { self.node = node }
    }

    /// WebKit's stable per-frame id (`WKFrameInfo._handle.frameID`).
    @MainActor
    public static func frameID(of info: WKFrameInfo) -> String? {
        let handleSelector = NSSelectorFromString("_handle")
        guard info.responds(to: handleSelector),
              let handle = info.perform(handleSelector)?.takeUnretainedValue() as? NSObject,
              handle.responds(to: NSSelectorFromString("frameID")),
              let number = handle.value(forKey: "frameID") as? NSNumber else {
            return nil
        }
        return number.stringValue
    }

    @MainActor
    private static func frameInfo(of node: AnyObject) -> WKFrameInfo? {
        if let info = node as? WKFrameInfo { return info }
        guard let object = node as? NSObject, object.responds(to: NSSelectorFromString("info")) else {
            return nil
        }
        return object.value(forKey: "info") as? WKFrameInfo
    }

    @MainActor
    private static func originKey(_ origin: WKSecurityOrigin) -> String {
        "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    @MainActor
    private static func mainFrameFallback(_ webView: WKWebView) -> BrowserReplFrame {
        BrowserReplFrame(
            frameID: "main",
            parentFrameID: nil,
            indexInParent: 0,
            info: nil,
            url: webView.url?.absoluteString ?? "",
            name: "",
            crossOrigin: false,
            childFramesUnread: true
        )
    }
}
