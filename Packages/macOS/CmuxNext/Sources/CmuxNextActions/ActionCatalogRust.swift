import CCmuxActionCatalogFFI
import Foundation

/// The ops of `cmux_action_catalog_call` (cmux-tui/crates/cmux-action-catalog/src/ffi.rs): one
/// JSON request (`{"op": …}`) in, one JSON object out. The `when` clause ops (`when_parse`,
/// `when_text`) cross a tree as one key per node (`{"has":"k"}`, `{"eq":["k",{"string":"v"}]}`, …;
/// the header of when_clause.rs); the menu bar ops cross rows (the header of status_menus.rs).
nonisolated enum ActionCatalogRust {
    static func call(_ request: [String: Any]) -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var reply: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = body.withUnsafeBytes { bytes in
            cmux_action_catalog_call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &reply, &length)
        }
        guard status == 0, let reply else { return nil }
        defer { cmux_action_catalog_reply_free(reply, length) }
        return (try? JSONSerialization.jsonObject(with: Data(bytes: reply, count: length))) as? [String: Any]
    }
}
