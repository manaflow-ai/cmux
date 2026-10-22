public import Foundation

extension DeepLink {
    /// RED stub: the workspace key with the same 128 bits as `ws_` link id `id`. Not written yet.
    public static func workspaceKey(linkID id: String) -> String? { nil }

    /// RED stub: the workspace link id `id` names among `workspaces`, by resource id only (the
    /// behavior before the fix).
    public static func workspace<W>(_ id: String, in workspaces: some Sequence<W>,
                                    resourceID: (W) -> String?, key: (W) -> String) -> W? {
        workspaces.first { resourceID($0) == id }
    }
}
