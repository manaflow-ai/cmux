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
        guard let root else { return [] }
        // WebKit's tree as JSON nodes, each naming its WKFrameInfo by index; Rust orders and links
        // them (cmux-browser-rules `frames.rs`, op `browser_rules_automation_frame_tree`).
        var infos: [WKFrameInfo] = []
        let reply = BrowserRulesFFI.call("frame_tree", ["root": node(root, into: &infos)])
        guard case .array(let records)? = reply else { return [] }
        return records.compactMap { record in
            guard case .object(let fields) = record, let id = fields["frameId"]?.stringValue,
                  let index = fields["url"]?.stringValue.flatMap(Int.init), infos.indices.contains(index) else { return nil }
            return FrameRecord(frameID: id, parentFrameID: fields["parentFrameId"]?.stringValue, info: infos[index])
        }
    }

    /// `node` as a frame-tree request node. Its `url` carries the index of its WKFrameInfo in
    /// `infos` (the record's url is read from the info itself); a node without an info or a frame
    /// id has none, and Rust drops it with its children.
    private static func node(_ node: AnyObject, into infos: inout [WKFrameInfo]) -> [String: Any] {
        guard node.responds(to: NSSelectorFromString("info")), node.responds(to: NSSelectorFromString("childFrames")),
              let info = node.value(forKey: "info") as? WKFrameInfo, let id = frameID(info) else { return [:] }
        infos.append(info)
        let children = ((node.value(forKey: "childFrames") as? [AnyObject]) ?? []).map { self.node($0, into: &infos) }
        return ["frameId": id, "url": String(infos.count - 1), "children": children]
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
