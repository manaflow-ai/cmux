import Foundation

/// The section layout reducer: `(document, op) -> document or reject`,
/// checking invariants L1-L6 (plans/cmux-next/sidebar-sections.md 4). It is
/// the store's own reducer (Rust `cmux_layout_reducer::sidebar_layout`, op
/// `sidebar_layout_reduce` of the layout reducer FFI), so the edit a client
/// overlays on its confirmed mirror is the one the store will commit
/// (cx-qvj1: the Swift copy had drifted).
public nonisolated enum SidebarLayoutReducer {
    /// The new document, or the reject. A change bumps `revision` by one;
    /// a no-op returns the document unchanged. When the FFI cannot answer
    /// (it never should), the document comes back unchanged: the store
    /// still checks the op.
    public static func reduce(_ document: SidebarLayoutDocument, _ op: SidebarLayoutOp) -> Result<SidebarLayoutDocument, SidebarLayoutReject> {
        // The document as the app encodes it (`revision` a number), never the
        // daemon's `sidebar_layout.get` JSON, whose `revision` is a string.
        let reply = RustSidebarClient.call("sidebar_layout_reduce", RustLayoutRequest(document: document, op: op), as: RustLayoutReply.self)
        if let next = reply?.document { return .success(next) }
        if let reason = reply?.reject, let reject = SidebarLayoutReject(rawValue: reason) { return .failure(reject) }
        return .success(document)
    }

    static func locate(_ id: LayoutItemID, in sections: [LayoutSection]) -> (Int, Int)? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.id == id }) { return (s, i) }
        }
        return nil
    }
}

private nonisolated struct RustLayoutRequest: Encodable {
    let document: SidebarLayoutDocument
    let op: SidebarLayoutOp
}

/// `{"document": ...}` or `{"reject": "<reason>"}`.
private nonisolated struct RustLayoutReply: Decodable {
    let document: SidebarLayoutDocument?
    let reject: String?
}
