public import Foundation

/// One harness of this app's acpmux daemon as Settings > Agents lists it
/// (`_acpmux/harnesses`): what it is, where it came from, and whether it can
/// start here.
public nonisolated struct AcpmuxHarnessRow: Sendable, Equatable {
    public var id: String
    /// A profile file's display name; nil for a found harness (the page names it by id).
    public var name: String?
    /// `acp`, `claude-stdio` or `terminal`.
    public var kind: String
    /// `managed`, `user-file`, `cmux-json` (profile files), `registry` (an installed ACP
    /// Registry agent), `path` (found on PATH) or `config` (acpmux's config.json).
    public var source: String
    /// Why it cannot start, when acpmux knows (a failed launcher or model probe).
    public var problem: String?

    public init(id: String, name: String? = nil, kind: String, source: String, problem: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
        self.problem = problem
    }

    /// The rows of a `_acpmux/harnesses` reply, sorted by id.
    static func rows(from reply: [String: Any]) -> [AcpmuxHarnessRow] {
        guard let harnesses = reply["harnesses"] as? [String: Any] else { return [] }
        return harnesses.compactMap { id, value -> AcpmuxHarnessRow? in
            guard let profile = value as? [String: Any] else { return nil }
            let kind = (profile["kind"] as? String) ?? "acp"
            let description = (profile["description"] as? String) ?? ""
            let source: String
            if let fileSource = profile["source"] as? String, profile["sourcePath"] != nil {
                source = fileSource
            } else if description.contains("ACP Registry") {
                source = "registry"
            } else if description == "found on PATH" || description.hasPrefix("imported from ~/.acpx")
                        || description.contains(" through ") {
                source = "path"
            } else {
                source = "config"
            }
            let name = (profile["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let problem = (profile["unavailable"] as? String) ?? (profile["probeError"] as? String)
            return AcpmuxHarnessRow(id: id, name: name, kind: kind, source: source, problem: problem)
        }.sorted { $0.id < $1.id }
    }
}

extension AcpmuxStatusClient {
    /// `_acpmux/harnesses`: every harness the daemon offers.
    @concurrent static func harnesses(socketPath: String, deadline: Duration = .seconds(5)) async throws -> ResultBox {
        ResultBox(try await call(socketPath: socketPath, method: "_acpmux/harnesses", deadline: deadline))
    }
}

extension AcpmuxEnvironment {
    /// The daemon's harnesses (Settings > Agents). Throws when the daemon does not answer.
    public nonisolated func harnessRows() async throws -> [AcpmuxHarnessRow] {
        AcpmuxHarnessRow.rows(from: try await AcpmuxStatusClient.harnesses(socketPath: socketPath).value)
    }

    /// The shell line that runs this app's acpmux with `arguments` against this daemon's home
    /// (a tagged build's `~/.acpmux/tags/<tag>`), each word single-quoted: Settings types it
    /// into a terminal tab for `harness login` and `harness registry`.
    public nonisolated func shellLine(_ arguments: [String]) -> String {
        let quote = { (word: String) in "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let env = childEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\(quote($0.value))" }
        return (env + [quote(executable.path)] + arguments.map(quote)).joined(separator: " ")
    }
}
