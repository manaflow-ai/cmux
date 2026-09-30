import CmuxFoundation
import CmuxMobileHost
import Foundation

/// Git and pull-request metadata resolved for one live agent session.
struct AgentSessionResolvedMetadata: Sendable {
    let branch: String?
    let worktree: String?
    let pullRequests: [AgentSessionPullRequest]
    let pullRequestsResolved: Bool
}

/// Resolves checkout metadata with one batched GitHub GraphQL request per refresh.
actor AgentSessionMetadataResolver {
    private let commandRunner: any CommandRunning
    private var cache: [String: (at: Date, metadata: AgentSessionResolvedMetadata)] = [:]
    private let cacheLifetime: TimeInterval = 15 * 60

    init(commandRunner: any CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    func currentBranch(directory: String) async -> String? {
        guard let branch = await command(directory: directory, arguments: ["branch", "--show-current"]),
              !branch.isEmpty else { return nil }
        return branch
    }

    func refresh(records: [AgentChatSessionRecord], now: Date = Date()) async -> [String: AgentSessionResolvedMetadata] {
        var unresolved: [(id: String, directory: String, branch: String, repo: (owner: String, name: String))] = []
        var result: [String: AgentSessionResolvedMetadata] = [:]
        for record in records {
            guard let directory = record.workingDirectory, !directory.isEmpty else { continue }
            guard let branch = await command(directory: directory, arguments: ["branch", "--show-current"]), !branch.isEmpty else { continue }
            let key = directory + "\n" + branch
            if let cached = cache[key], now.timeIntervalSince(cached.at) < cacheLifetime {
                result[record.sessionID] = cached.metadata
                continue
            }
            guard let remote = await command(directory: directory, arguments: ["remote", "get-url", "origin"]),
                  let repo = Self.repository(from: remote) else { continue }
            unresolved.append((record.sessionID, directory, branch, repo))
        }

        let unique = Dictionary(grouping: unresolved, by: { $0.directory + "\n" + $0.branch })
        var aliases: [String: String] = [:]
        for (index, key) in unique.keys.sorted().enumerated() {
            aliases["r\(index)"] = key
        }
        if !aliases.isEmpty {
            let query = Self.graphQLQuery(aliases: aliases, records: unresolved)
            if let raw = await command(directory: ".", executable: "gh", arguments: ["api", "graphql", "-f", "query=\(query)"]),
               let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = object["data"] as? [String: Any] {
                for (alias, key) in aliases.sorted(by: { $0.key < $1.key }) {
                    let prs = Self.pullRequests(from: response[alias])
                    let metadata = AgentSessionResolvedMetadata(
                        branch: unresolved.first(where: { $0.directory + "\n" + $0.branch == key })?.branch,
                        worktree: unresolved.first(where: { $0.directory + "\n" + $0.branch == key })?.directory,
                        pullRequests: prs,
                        pullRequestsResolved: true
                    )
                    cache[key] = (now, metadata)
                    for item in unique[key] ?? [] { result[item.id] = metadata }
                }
            }
        }
        return result
    }

    private func command(directory: String, arguments: [String]) async -> String? {
        await command(directory: directory, executable: "git", arguments: ["-C", directory] + arguments)
    }

    private func command(directory: String, executable: String, arguments: [String]) async -> String? {
        await commandRunner.runStandardOutput(directory: directory, executable: executable, arguments: arguments, timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repository(from remote: String) -> (owner: String, name: String)? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        let path = value.components(separatedBy: ":").last ?? value
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return (String(parts[parts.count - 2]), String(parts.last!))
    }

    private static func graphQLQuery(aliases: [String: String], records: [(id: String, directory: String, branch: String, repo: (owner: String, name: String))]) -> String {
        let unique = Dictionary(grouping: records, by: { $0.directory + "\n" + $0.branch })
        let bodies = aliases.sorted { $0.key < $1.key }.compactMap { alias, key -> String? in
            guard let item = unique[key]?.first else { return nil }
            let owner = Self.graphQLString(item.repo.owner)
            let name = Self.graphQLString(item.repo.name)
            let branch = Self.graphQLString(item.branch)
            return "\(alias): repository(owner: \(owner), name: \(name)) { pullRequests(first: 20, states: [OPEN, CLOSED, MERGED], headRefName: \(branch)) { nodes { number state title } } }"
        }
        return "query { \(bodies.joined(separator: " ")) }"
    }

    private static func graphQLString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "\"\""
        }
        return encoded
    }

    private static func pullRequests(from value: Any?) -> [AgentSessionPullRequest] {
        guard let repository = value as? [String: Any],
              let connection = repository["pullRequests"] as? [String: Any],
              let nodes = connection["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node in
            guard let number = node["number"] as? Int, let state = node["state"] as? String else { return nil }
            return AgentSessionPullRequest(number: number, state: state, title: node["title"] as? String)
        }
    }
}
