import Foundation

/// Reads the GitHub repository named by a workspace's `origin` remote.
///
/// A missing repository, a non-GitHub remote and a command failure all intentionally return nil:
/// callers then leave issue references as ordinary text.
public nonisolated struct AgentPaneGitHubRepository {
    public init() {}

    public static func read(at path: String) async -> String? {
        await Task.detached(priority: .utility) {
            readSync(at: path)
        }.value
    }

    private static func readSync(at path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "remote", "get-url", "origin"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            // concurrency-allow: readSync runs only inside the detached utility task; git output is bounded.
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              // concurrency-allow: this read runs only inside the detached utility task after git exits.
              let remote = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        return parse(remote)
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
