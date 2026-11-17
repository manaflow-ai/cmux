import Foundation

nonisolated extension PageInfoSite {
    /// Splits a site name for truncation: the head may be cut, the tail always shows. A host keeps
    /// its registrable domain and port in the tail, so a long host cannot hide the real site behind
    /// a trusted-looking prefix; any other name keeps its last 16 characters.
    ///
    /// The registrable domain comes from the Public Suffix List, private section included, so
    /// `paypal-login.evil.github.io` keeps `evil.github.io`. A host the list has no site for (a
    /// public suffix itself, an IP address) is all tail. Without a list, or for a host the list
    /// cannot read (non-ASCII), the tail is a guess: the last two labels, or three when the
    /// second-level label is short (`co.uk`).
    /// - Parameters:
    ///   - name: a host with an optional port, or any other name (a path).
    ///   - registrableDomain: a host's registrable domain, nil when it has none; nil when there is
    ///     no list. The app's one list (``PublicSuffixList/shared``) by default, which parses the
    ///     bundled list on its first read: a main-thread caller passes the lookup it read in the
    ///     background (``PublicSuffixList/sharedRegistrableDomainInBackground(read:)``) instead.
    static func splitName(
        _ name: String,
        registrableDomain: ((String) -> String?)? = PublicSuffixList.sharedRegistrableDomain
    ) -> (head: String, tail: String) {
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
        let keep: Int
        if let registrableDomain, host.allSatisfy(\.isASCII) {
            keep = registrableDomain(String(host)).map { $0.split(separator: ".").count } ?? labels.count
        } else {
            keep = labels.count > 2 && labels[labels.count - 2].count <= 3 ? 3 : 2
        }
        guard labels.count > keep else { return ("", name) }
        return (labels.dropLast(keep).joined(separator: ".") + ".", labels.suffix(keep).joined(separator: ".") + port)
    }

    /// `name` as it fits `width`: whole when it fits, else its head cut at the end (with an
    /// ellipsis) before its whole tail. A name with no head, or whose tail alone is too wide, is
    /// returned for the label to cut at its start.
    /// - Parameters:
    ///   - width: the room the name has.
    ///   - registrableDomain: the lookup ``splitName(_:registrableDomain:)`` cuts with; nil (the
    ///     list not read yet, or missing) guesses. Never the default there: layout runs on the
    ///     main thread, which must not parse the list.
    ///   - measure: the width a text draws at.
    static func fittedName(
        _ name: String,
        width: CGFloat,
        registrableDomain: ((String) -> String?)?,
        measure: (String) -> CGFloat
    ) -> String {
        guard measure(name) > width else { return name }
        let (head, tail) = splitName(name, registrableDomain: registrableDomain)
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

nonisolated extension PublicSuffixList {
    /// ``sharedRegistrableDomain`` read off the calling thread: its first read parses the bundled
    /// list (10,000+ rules), which Page Info's header, laid out on the main thread, must not wait
    /// for. Later reads return the kept list at once.
    /// - Parameter read: the read to run in the background (tests); ``sharedRegistrableDomain``.
    static func sharedRegistrableDomainInBackground(
        read: @escaping @Sendable () -> (@Sendable (String) -> String?)? = { PublicSuffixList.sharedRegistrableDomain }
    ) async -> (@Sendable (String) -> String?)? {
        await Task.detached(priority: .utility) { read() }.value
    }
}
