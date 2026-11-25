import Foundation

nonisolated extension PageInfoSite {
    /// Splits a site name for truncation: the head may be cut, the tail always shows. A host keeps
    /// its registrable domain and port in the tail (the last two labels, or three when the
    /// second-level label is a short public one such as `co.uk`), so a long host cannot hide the
    /// real site behind a trusted-looking prefix; any other name keeps its last 16 characters.
    static func splitName(_ name: String) -> (head: String, tail: String) {
        var host = Substring(name)
        var port = ""
        if let colon = name.lastIndex(of: ":") {
            let digits = name[name.index(after: colon)...]
            if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
                port = String(name[colon...])
                host = name[..<colon]
            }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let isHost = labels.count >= 2 && labels.last?.isEmpty == false && labels.first?.isEmpty == false
            && !host.contains { $0.isWhitespace || $0 == "/" }
        guard isHost else {
            let tail = name.suffix(16)
            return (String(name.dropLast(tail.count)), String(tail))
        }
        let keep = labels.count > 2 && labels[labels.count - 2].count <= 3 ? 3 : 2
        guard labels.count > keep else { return ("", name) }
        return (labels.dropLast(keep).joined(separator: ".") + ".", labels.suffix(keep).joined(separator: ".") + port)
    }

    /// `name` as it fits `width`: whole when it fits, else its head cut at the end (with an
    /// ellipsis) before its whole tail. A name with no head, or whose tail alone is too wide, is
    /// returned for the label to cut at its start.
    /// - Parameters:
    ///   - width: the room the name has.
    ///   - measure: the width a text draws at.
    static func fittedName(_ name: String, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(name) > width else { return name }
        let (head, tail) = splitName(name)
        guard !head.isEmpty else { return name }
        var kept = Substring(head)
        while !kept.isEmpty {
            kept = kept.dropLast()
            let candidate = String(kept) + "…" + tail
            if measure(candidate) <= width { return candidate }
        }
        return "…" + tail
    }
}
