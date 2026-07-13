import Foundation

/// A transcript-derived path with de-duplicated provenance and its last position.
public struct ChatArtifactIndexedReference: Sendable, Equatable, Codable, Identifiable {
    /// Transcript path exactly as parsed.
    public let path: String
    /// Highest-precedence provenance observed for the path.
    public let provenance: ChatArtifactProvenance
    /// Last transcript sequence that mentioned, attached, or edited the path.
    public let lastReferencedSeq: Int

    /// Stable identity used by ordering and paging.
    public var id: String { path }

    /// Creates an indexed reference.
    public init(path: String, provenance: ChatArtifactProvenance, lastReferencedSeq: Int) {
        self.path = path
        self.provenance = provenance
        self.lastReferencedSeq = lastReferencedSeq
    }

    /// Derives one record per normalized path from parsed transcript messages.
    ///
    /// Agent edits outrank attachments, which outrank read-only references;
    /// every occurrence still advances the path's last-reference sequence.
    /// Relative paths are lexically resolved against the session working
    /// directory without accessing the filesystem.
    ///
    /// - Parameters:
    ///   - messages: Parsed transcript messages to inspect.
    ///   - workingDirectory: Absolute session directory used for relative paths.
    /// - Returns: De-duplicated artifact references with normalized paths.
    public static func derive(
        from messages: [ChatMessage],
        workingDirectory: String? = nil
    ) -> [ChatArtifactIndexedReference] {
        var byPath: [String: ChatArtifactIndexedReference] = [:]
        for message in messages {
            let occurrences: [(String, ChatArtifactProvenance)]
            switch message.kind {
            case .fileEdit(let edit):
                occurrences = [(edit.filePath, .created)]
            case .attachment(let attachment):
                occurrences = attachment.hostPath.map { [($0, .attached)] } ?? []
            case .toolUse(let toolUse):
                let provenance: ChatArtifactProvenance = Self.isFileMutationTool(toolUse.toolName)
                    ? .created
                    : .referenced
                occurrences = (toolUse.referencedPaths ?? []).map { ($0, provenance) }
            case .prose, .thought, .terminal, .permissionRequest, .question, .status, .unsupported:
                occurrences = []
            }
            for (rawPath, provenance) in occurrences {
                guard let path = Self.normalizedPath(rawPath, workingDirectory: workingDirectory) else {
                    continue
                }
                let previous = byPath[path]
                byPath[path] = ChatArtifactIndexedReference(
                    path: path,
                    provenance: Self.higherPrecedence(previous?.provenance, provenance),
                    lastReferencedSeq: max(previous?.lastReferencedSeq ?? Int.min, message.seq)
                )
            }
        }
        return Array(byPath.values)
    }

    private static func normalizedPath(_ path: String, workingDirectory: String?) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute: String
        if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else if let workingDirectory {
            let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cwd.hasPrefix("/") else { return trimmed }
            absolute = (cwd as NSString).appendingPathComponent(trimmed)
        } else {
            return trimmed
        }
        // Purely lexical normalization (drop ".", collapse ".."): unlike
        // NSString.standardizingPath, this never consults the filesystem, so
        // derivation stays deterministic for paths that no longer exist.
        var components: [String] = []
        for component in absolute.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        let standardized = "/" + components.joined(separator: "/")
        if standardized == "/tmp" {
            return "/private/tmp"
        }
        if standardized.hasPrefix("/tmp/") {
            return "/private" + standardized
        }
        return standardized
    }

    private static func isFileMutationTool(_ toolName: String) -> Bool {
        let normalized = toolName.split(separator: ".").last.map(String.init) ?? toolName
        return normalized.lowercased() == "apply_patch"
    }

    private static func higherPrecedence(
        _ lhs: ChatArtifactProvenance?,
        _ rhs: ChatArtifactProvenance
    ) -> ChatArtifactProvenance {
        guard let lhs else { return rhs }
        return Self.rank(lhs) <= Self.rank(rhs) ? lhs : rhs
    }

    private static func rank(_ provenance: ChatArtifactProvenance) -> Int {
        switch provenance {
        case .created: 0
        case .attached: 1
        case .referenced: 2
        }
    }
}
