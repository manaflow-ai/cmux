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

    /// Derives one record per path from parsed transcript messages.
    ///
    /// Agent edits outrank attachments, which outrank read-only references;
    /// every occurrence still advances the path's last-reference sequence.
    public static func derive(from messages: [ChatMessage]) -> [ChatArtifactIndexedReference] {
        var byPath: [String: ChatArtifactIndexedReference] = [:]
        for message in messages {
            let occurrences: [(String, ChatArtifactProvenance)]
            switch message.kind {
            case .fileEdit(let edit):
                occurrences = [(edit.filePath, .created)]
            case .attachment(let attachment):
                occurrences = attachment.hostPath.map { [($0, .attached)] } ?? []
            case .toolUse(let toolUse):
                occurrences = (toolUse.referencedPaths ?? []).map { ($0, .referenced) }
            case .prose, .thought, .terminal, .permissionRequest, .question, .status, .unsupported:
                occurrences = []
            }
            for (path, provenance) in occurrences where !path.isEmpty {
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
