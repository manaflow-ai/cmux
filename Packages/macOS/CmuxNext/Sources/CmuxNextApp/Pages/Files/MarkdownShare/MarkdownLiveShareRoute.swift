import Foundation

/// A request path of the local live server (plans/cmux-next/markdown-omnibar-DESIGN.md section
/// 4.1): `/md/<token>/<name>` is the page, `/md/<token>/<name>/events` its reload stream. Any
/// other path, or one with `..`, routes nowhere and answers 404.
nonisolated enum MarkdownLiveShareRoute: Equatable, Sendable {
    case page(token: String)
    case events(token: String)

    init?(path: String) {
        let path = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              parts.count == 3 || parts.count == 4, parts[0] == "md" else { return nil }
        let token = parts[1]
        guard token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        if parts.count == 3 {
            self = .page(token: token)
        } else if parts[3] == "events" {
            self = .events(token: token)
        } else {
            return nil
        }
    }
}
