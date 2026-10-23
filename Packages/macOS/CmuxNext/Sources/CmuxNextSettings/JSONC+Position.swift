extension JSONC {
    /// Where the member at `path` starts in `source` (its key's opening quote), as a 1-based line
    /// and column (UTF-16 code units, as the code editor counts); nil when the source does not
    /// parse or has no such member.
    ///
    /// - Parameters:
    ///   - path: Object keys from the root, at least one.
    ///   - source: A JSONC document.
    public static func position(of path: [String], in source: String) -> (line: Int, column: Int)? {
        let bytes = Array(source.utf8)
        guard !path.isEmpty, let root = try? parseRoot(bytes) else { return nil }
        var node = root
        var start: Int?
        for key in path {
            guard case .object(let object) = node, let member = object.members.last(where: { $0.key == key }) else { return nil }
            start = member.keyStart
            node = member.node
        }
        guard let offset = start else { return nil }
        let before = String(decoding: bytes[..<offset], as: UTF8.self)
        let lines = before.split(separator: "\n", omittingEmptySubsequences: false)
        return (lines.count, (lines.last.map { String($0).utf16.count } ?? 0) + 1)
    }
}
