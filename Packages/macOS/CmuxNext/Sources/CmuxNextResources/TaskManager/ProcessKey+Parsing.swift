import Foundation

public extension ProcessKey {
    /// Parses what `cmux app kill-process` takes: a pid (`4242`, this Mac)
    /// or `host:pid` (`local:4242`, `m-cloud:4242`). Nil for anything else
    /// or a pid that is not positive.
    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard let last = parts.last, let pid = Int32(last), pid > 0, parts.count <= 2 else { return nil }
        let host = parts.count == 2 ? String(parts[0]) : ProcessKey.localHost
        guard !host.isEmpty else { return nil }
        self.init(host: host, pid: pid)
    }
}
