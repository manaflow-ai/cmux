import Foundation

/// Page scripts for `browser.page.storage.*` (the old `cmux browser storage`).
extension BrowserPageScripts {
    enum StorageArea: String, Sendable {
        case local, session
    }

    enum StorageOperation: Sendable, Equatable {
        /// One key's value, or every key and value when `key` is nil.
        case get(StorageArea, key: String?)
        case set(StorageArea, key: String, value: String)
        /// Clears the whole area, as the old CLI did.
        case clear(StorageArea)
    }

    static func storage(_ operation: StorageOperation) -> String {
        let area: StorageArea
        let body: String
        switch operation {
        case .get(let chosen, let key?):
            area = chosen
            body = "return { value: { key: \(literal(key)), value: st.getItem(\(literal(key))) } };"
        case .get(let chosen, nil):
            area = chosen
            body = "const all = {}; for (let i = 0; i < st.length; i++) { const k = st.key(i); all[k] = st.getItem(k); } "
                + "return { value: { key: null, value: all } };"
        case .set(let chosen, let key, let value):
            area = chosen
            body = "st.setItem(\(literal(key)), \(literal(value))); return { value: { key: \(literal(key)) } };"
        case .clear(let chosen):
            area = chosen
            body = "st.clear(); return { value: { cleared: true } };"
        }
        return wrap("""
        let st = null;
        try { st = window.\(area == .session ? "sessionStorage" : "localStorage"); } catch (e) { return { error: 'Storage unavailable: ' + String(e) }; }
        if (!st) { return { error: 'Storage unavailable' }; }
        try { \(body) } catch (e) { return { error: String(e) }; }
        """)
    }
}
