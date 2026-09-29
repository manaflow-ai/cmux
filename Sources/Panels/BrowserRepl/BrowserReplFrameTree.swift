import AppKit
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
@MainActor
enum BrowserReplFrameTree {
    static func frames(of webView: WKWebView) async -> [BrowserReplFrame] {
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

    /// The frame with `frameID`, or the main frame for `nil`.
    static func frame(_ frameID: String?, in webView: WKWebView) async -> BrowserReplFrame? {
        let all = await frames(of: webView)
        guard let frameID, !frameID.isEmpty else { return all.first }
        return all.first { $0.frameID == frameID }
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
