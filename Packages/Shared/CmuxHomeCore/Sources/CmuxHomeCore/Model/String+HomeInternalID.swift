import Foundation

extension String {
    /// Whether this text is an internal Home id (`addr_…`, `user_…`, `agent_…`, `conv_…`, …)
    /// rather than a name a person can read.
    ///
    /// Owners and the daemon key people and conversations by these ids; none of them is ever a
    /// name. A view that falls back to an id when a name is missing shows `addr_ABREQ2…` to the
    /// user, so every name shown in Home goes through this check first.
    public var isHomeInternalID: Bool {
        guard let underscore = firstIndex(of: "_") else { return false }
        let prefix = self[..<underscore]
        guard Self.homeIDPrefixes.contains(String(prefix)) else { return false }
        let rest = self[index(after: underscore)...]
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Id prefixes the Home owners mint (home-messaging.md section 2) and the local placeholders.
    private static let homeIDPrefixes: Set<String> = [
        "addr", "user", "agent", "conv", "inv", "msg", "team", "inst", "grant", "task", "vm",
    ]
}
