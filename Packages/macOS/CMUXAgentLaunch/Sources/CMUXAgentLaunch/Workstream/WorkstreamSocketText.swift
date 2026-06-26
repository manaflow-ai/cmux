import Foundation

extension String {
    /// Character budget for primary `feed.*` socket text fields (tool input,
    /// plan, prompt, free-form message text). Byte-faithful port of the legacy
    /// `FeedSocketEncoding.primaryTextLimit`.
    static let feedSocketPrimaryTextLimit = 8_000

    /// Character budget for secondary `feed.*` socket text fields (headers,
    /// option labels and descriptions, stop reasons, todo content).
    /// Byte-faithful port of the legacy `FeedSocketEncoding.secondaryTextLimit`.
    static let feedSocketSecondaryTextLimit = 2_000

    /// Truncates the string to `limit` characters for the `feed.*` socket wire,
    /// appending an ellipsis when shortened. Byte-faithful port of the legacy
    /// `FeedSocketEncoding.limitedText`.
    func feedSocketTruncated(limit: Int) -> (text: String, truncated: Bool) {
        guard count > limit else { return (self, false) }
        let end = index(startIndex, offsetBy: max(limit - 3, 0))
        return (String(self[..<end]) + "...", true)
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Writes `value` truncated to `limit` characters under `key`, adding a
    /// `"<key>_truncated": true` flag when the text was shortened. Byte-faithful
    /// port of the legacy `FeedSocketEncoding.assignLimitedText`.
    mutating func assignFeedSocketTruncated(
        _ value: String,
        key: String,
        limit: Int = String.feedSocketPrimaryTextLimit
    ) {
        let limited = value.feedSocketTruncated(limit: limit)
        self[key] = limited.text
        if limited.truncated {
            self["\(key)_truncated"] = true
        }
    }
}
