import Foundation
public import WebKit

/// One frame of a tab, as `frames.list` reports it.
public struct FrameRecord {
    public let frameID: String
    public let parentFrameID: String?
    public let info: WKFrameInfo
    public var url: String { info.request.url?.absoluteString ?? "" }
    public var isMain: Bool { parentFrameID == nil }
}

/// Reads a web view's frame tree through WebKit SPI (`-[WKWebView _frames:]`,
/// `-[WKFrameInfo _handle].frameID`). Without the SPI only the main frame is
/// known, through a main-frame script call. Frame ids are WebKit's frame
/// handle ids, opaque strings to the protocol.
@MainActor
enum FrameTree {
    private typealias FramesIMP = @convention(c) (AnyObject, Selector, @escaping @convention(block) (AnyObject?) -> Void) -> Void

    static var isAvailable: Bool { WKWebView.instancesRespond(to: NSSelectorFromString("_frames:")) }

    /// Parents before children, document order.
    static func read(_ webView: WKWebView) async -> [FrameRecord] {
        let selector = NSSelectorFromString("_frames:")
        guard webView.responds(to: selector) else { return [] }
        let imp = unsafeBitCast(webView.method(for: selector), to: FramesIMP.self)
        // WebKit calls back on the main thread with the tree it owns.
        let root = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedNode, Never>) in
            imp(webView, selector) { node in continuation.resume(returning: UncheckedNode(value: node)) }
        }.value
        var out: [FrameRecord] = []
        if let root { flatten(root, parent: nil, into: &out) }
        return out
    }

    private static func flatten(_ node: AnyObject, parent: String?, into out: inout [FrameRecord]) {
        guard node.responds(to: NSSelectorFromString("info")), node.responds(to: NSSelectorFromString("childFrames")),
              let info = node.value(forKey: "info") as? WKFrameInfo, let id = frameID(info) else { return }
        out.append(FrameRecord(frameID: id, parentFrameID: parent, info: info))
        for child in (node.value(forKey: "childFrames") as? [AnyObject]) ?? [] {
            flatten(child, parent: id, into: &out)
        }
    }

    static func frameID(_ info: WKFrameInfo) -> String? {
        guard info.responds(to: NSSelectorFromString("_handle")),
              let handle = info.value(forKey: "_handle") as? NSObject,
              handle.responds(to: NSSelectorFromString("frameID")),
              let id = handle.value(forKey: "frameID") as? NSNumber else { return nil }
        return String(id.uint64Value)
    }
}

/// A frame-tree node handed across the callback; only read on the main actor.
private nonisolated struct UncheckedNode: @unchecked Sendable {
    let value: AnyObject?
}
