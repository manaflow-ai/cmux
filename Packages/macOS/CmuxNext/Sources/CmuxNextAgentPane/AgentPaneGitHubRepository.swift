import Foundation
import CmuxNextWakeups

/// Reads the GitHub repository named by a workspace's `origin` remote.
///
/// A missing repository, a non-GitHub remote and a command failure all intentionally return nil:
/// callers then leave issue references as ordinary text.
public nonisolated struct AgentPaneGitHubRepository {
    public init() {}

    public static func read(at path: String?) async -> String? {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/git"), ["-C", path, "remote", "get-url", "origin"])
        guard let outcome = try? await AsyncProcess().run(request), outcome.succeeded else { return nil }
        return parse(outcome.text)
    }

    public static func parse(_ remote: String) -> String? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let match = value.range(of: "^git@github\\.com:", options: .regularExpression) {
            path = String(value[match.upperBound...])
        } else if let url = URL(string: value), url.host?.lowercased() == "github.com" {
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count == 2 else { return nil }
        let owner = components[0]
        let repository = components[1].hasSuffix(".git") ? String(components[1].dropLast(4)) : components[1]
        guard validComponent(owner), validComponent(repository) else { return nil }
        return "\(owner)/\(repository)"
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
