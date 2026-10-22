public import Foundation

extension DeepLink {
    /// The workspace key with the same 128 bits as `ws_` link id `id`: `ws_66ec22feb08e…` is key
    /// `66ec22fe-b08e-…` (the lowercase dashed UUID a daemon lists as a workspace's `key`, the app's
    /// `WorkspaceModel.id`). Nil when `id` is no `ws_` resource id.
    ///
    /// A Chief and its subagents know a subagent's workspace by the key they chose for it, and
    /// wrote `cmux://workspace/ws_<key hex>` for it (Lawrence 2026-10-22: a489's link never opened).
    /// The resource id is minted apart from the key, so that link named no workspace. Both are 128
    /// random bits, so the key form can only ever name the one workspace that key belongs to.
    public static func workspaceKey(linkID id: String) -> String? {
        guard isResourceID(id, prefix: "ws_") else { return nil }
        let hex = Array(id.dropFirst(3))
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
    }

    /// The workspace link id `id` (`cmux://workspace/<id>`) names among `workspaces`: the one whose
    /// resource id it is, else the one whose key it carries in `ws_` form (``workspaceKey(linkID:)``).
    /// Nil when none does.
    ///
    /// - Parameters:
    ///   - id: The link's `ws_` id.
    ///   - workspaces: Every workspace the app has, on every connected machine and session.
    ///   - resourceID: A workspace's `ws_` resource id, nil before its daemon reports one.
    ///   - key: A workspace's key (lowercase dashed UUID).
    public static func workspace<W>(_ id: String, in workspaces: some Sequence<W>,
                                    resourceID: (W) -> String?, key: (W) -> String) -> W? {
        let keyed = workspaceKey(linkID: id)
        var byKey: W?
        for workspace in workspaces {
            if resourceID(workspace) == id { return workspace }
            if byKey == nil, let keyed, key(workspace).lowercased() == keyed { byKey = workspace }
        }
        return byKey
    }
}
