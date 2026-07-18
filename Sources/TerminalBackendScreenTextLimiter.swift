/// UTF-8-safe tail bounds for the package's external screen-text contract.
struct TerminalBackendScreenTextLimiter {
    func tail(_ text: String, maximumRows: Int, maximumBytes: Int) -> String? {
        guard maximumRows > 0, maximumBytes > 0 else { return nil }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        let candidate = rows.suffix(maximumRows).joined(separator: "\n")
        guard candidate.utf8.count > maximumBytes else { return candidate }
        var start = candidate.endIndex
        var retainedBytes = 0
        while start > candidate.startIndex {
            let previous = candidate.index(before: start)
            let characterBytes = candidate[previous..<start].utf8.count
            guard retainedBytes + characterBytes <= maximumBytes else { break }
            retainedBytes += characterBytes
            start = previous
        }
        return String(candidate[start...])
    }
}
