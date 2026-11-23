extension JSONC {
    /// Where the member at `path` starts in `source` (its key's opening quote), as a 1-based line
    /// and column (UTF-16 code units, as the code editor counts); nil when the source does not
    /// parse or has no such member.
    ///
    /// - Parameters:
    ///   - path: Object keys from the root, at least one.
    ///   - source: A JSONC document.
    public static func position(of path: [String], in source: String) -> (line: Int, column: Int)? {
        guard !path.isEmpty, let reply = CmuxSettingsFFI.call("jsonc.position", ["source": source, "path": path]),
              let line = reply["line"] as? Int, let column = reply["column"] as? Int else { return nil }
        return (line, column)
    }
}
