import CmuxNextBrowser
import CmuxNextSettings

extension BrowserURLFilter {
    /// Pure: the managed policy's `URLBlocklist` and `URLAllowlist` (forced values only).
    init(managedPolicy policy: [String: JSONValue]) {
        func strings(_ key: String) -> [String] {
            guard case .array(let items) = policy[key] else { return [] }
            return items.compactMap(\.stringValue)
        }
        self.init(blocklist: strings("URLBlocklist"), allowlist: strings("URLAllowlist"))
    }
}
