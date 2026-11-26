import Foundation

/// A transcript-derived path with de-duplicated provenance and its last position.
public struct ChatArtifactIndexedReference: Sendable, Equatable, Codable, Identifiable {
    /// Canonical display path when the file exists, otherwise its lexical path.
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

    /// Derives one record per canonical path identity from parsed transcript messages.
    ///
    /// Agent edits outrank attachments, which outrank read-only references;
    /// every occurrence still advances the path's last-reference sequence.
    /// Existing absolute paths resolve filesystem aliases after lexical
    /// normalization. Missing paths stay lexical so deleted artifacts remain.
    ///
    /// - Parameters:
    ///   - messages: Parsed transcript messages to inspect.
    ///   - supplementalReferences: Raw pre-budget and artifacts-only parser
    ///     occurrences that are absent from the visible message stream.
    ///   - workingDirectory: Absolute session directory used for relative paths.
    ///   - canonicalizer: Filesystem identity operation used after lexical normalization.
    /// - Returns: De-duplicated artifact references with canonical display paths.
    public static func derive(
        from messages: [ChatMessage],
        supplementalReferences: [ChatArtifactTranscriptReference] = [],
        workingDirectory: String? = nil,
        canonicalizer: ChatArtifactPathCanonicalizer = ChatArtifactPathCanonicalizer()
    ) -> [ChatArtifactIndexedReference] {
        var byPath: [String: ChatArtifactIndexedReference] = [:]
        var canonicalPathByLexicalPath: [String: String] = [:]
        let detector = TerminalArtifactPathDetector()
        let normalizer = ChatArtifactPathNormalizer(workingDirectory: workingDirectory)
        for message in messages {
            var structuredOccurrences: [(String, ChatArtifactProvenance)] = []
            var textOccurrences: [String] = []
            switch message.kind {
            case .fileEdit(let edit):
                structuredOccurrences = [(edit.filePath, .created)]
            case .attachment(let attachment):
                structuredOccurrences = attachment.hostPath.map { [($0, .attached)] } ?? []
            case .toolUse(let toolUse):
                let provenance: ChatArtifactProvenance = Self.isFileMutationTool(toolUse.toolName)
                    ? .created
                    : .referenced
                structuredOccurrences = (toolUse.referencedPaths ?? []).map { ($0, provenance) }
                if let output = toolUse.output {
                    textOccurrences = detector.paths(in: output)
                }
            case .prose(let prose):
                textOccurrences = detector.paths(in: prose.text)
            case .thought(let thought):
                textOccurrences = detector.paths(in: thought.text)
            case .terminal(let terminal):
                textOccurrences = detector.paths(in: terminal.command)
                if let output = terminal.output {
                    textOccurrences.append(contentsOf: detector.paths(in: output))
                }
            case .permissionRequest, .question, .status, .unsupported:
                break
            }
            for (rawPath, provenance) in structuredOccurrences {
                guard let path = normalizer.structuredPath(rawPath) else {
                    continue
                }
                Self.merge(
                    path: path,
                    provenance: provenance,
                    seq: message.seq,
                    canonicalizer: canonicalizer,
                    canonicalPathByLexicalPath: &canonicalPathByLexicalPath,
                    into: &byPath
                )
            }
            for rawPath in textOccurrences where
                ChatArtifactPathNormalizer.isAbsoluteFreeTextCandidate(rawPath) {
                guard let path = normalizer.freeTextPath(rawPath) else { continue }
                Self.merge(
                    path: path,
                    provenance: .referenced,
                    seq: message.seq,
                    canonicalizer: canonicalizer,
                    canonicalPathByLexicalPath: &canonicalPathByLexicalPath,
                    into: &byPath
                )
            }
        }
        for reference in supplementalReferences {
            let path: String?
            if ChatArtifactPathNormalizer.isAbsoluteFreeTextCandidate(reference.path) {
                path = normalizer.freeTextPath(reference.path)
            } else {
                path = normalizer.structuredPath(reference.path)
            }
            guard let path else { continue }
            Self.merge(
                path: path,
                provenance: reference.provenance,
                seq: reference.seq,
                canonicalizer: canonicalizer,
                canonicalPathByLexicalPath: &canonicalPathByLexicalPath,
                into: &byPath
            )
        }
        return Array(byPath.values)
    }

    private static func merge(
        path: String,
        provenance: ChatArtifactProvenance,
        seq: Int,
        canonicalizer: ChatArtifactPathCanonicalizer,
        canonicalPathByLexicalPath: inout [String: String],
        into byPath: inout [String: ChatArtifactIndexedReference]
    ) {
        let canonicalPath: String
        if let cached = canonicalPathByLexicalPath[path] {
            canonicalPath = cached
        } else {
            canonicalPath = canonicalizer.canonicalPathKey(for: path)
            canonicalPathByLexicalPath[path] = canonicalPath
        }
        let previous = byPath[canonicalPath]
        byPath[canonicalPath] = ChatArtifactIndexedReference(
            path: canonicalPath,
            provenance: Self.higherPrecedence(previous?.provenance, provenance),
            lastReferencedSeq: max(previous?.lastReferencedSeq ?? Int.min, seq)
        )
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
