import Foundation

/// A transcript-derived path with de-duplicated provenance and its last position.
public struct ChatArtifactIndexedReference: Sendable, Equatable, Codable, Identifiable {
    private static let maximumDerivedPathCount = 1_024
    private static let maximumCanonicalAliasCount = 2_048
    /// Canonical display path when the file exists, otherwise its lexical path.
    public let path: String
    /// Highest-precedence provenance observed for the path.
    public let provenance: ChatArtifactProvenance
    /// Last transcript sequence that mentioned, attached, or edited the path.
    public let lastReferencedSeq: Int
    /// Most recent transcript occurrence that authorizes capture, if any.
    public let captureAuthorization: ChatArtifactCaptureAuthorization?

    /// Stable identity used by ordering and paging.
    public var id: String { path }

    /// Creates an indexed reference from one provenance-bearing occurrence.
    ///
    /// Created and attached provenance authorizes capture at `lastReferencedSeq`.
    /// Use ``init(path:provenance:lastReferencedSeq:captureAuthorization:)``
    /// when aggregate provenance and the latest authorization differ.
    public init(path: String, provenance: ChatArtifactProvenance, lastReferencedSeq: Int) {
        self.init(
            path: path,
            provenance: provenance,
            lastReferencedSeq: lastReferencedSeq,
            captureAuthorization: provenance.captureAuthorization(sequence: lastReferencedSeq)
        )
    }

    /// Creates an indexed reference with independently tracked display provenance and capture authorization.
    ///
    /// - Parameters:
    ///   - path: Canonical display path.
    ///   - provenance: Highest-precedence provenance observed for the path.
    ///   - lastReferencedSeq: Last transcript sequence that mentioned the path.
    ///   - captureAuthorization: Most recent capture-authorizing occurrence, if any.
    public init(
        path: String,
        provenance: ChatArtifactProvenance,
        lastReferencedSeq: Int,
        captureAuthorization: ChatArtifactCaptureAuthorization?
    ) {
        self.path = path
        self.provenance = provenance
        self.lastReferencedSeq = lastReferencedSeq
        self.captureAuthorization = captureAuthorization
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
                structuredOccurrences = [(edit.filePath, .referenced)]
            case .attachment(let attachment):
                structuredOccurrences = attachment.hostPath.map { [($0, .attached)] } ?? []
            case .toolUse(let toolUse):
                let provenance: ChatArtifactProvenance = toolUse.authorizesCreatedArtifactProvenance
                    ? .created
                    : .referenced
                structuredOccurrences = (toolUse.referencedPaths ?? [])
                    .prefix(Self.maximumDerivedPathCount)
                    .map { ($0, provenance) }
                if let output = toolUse.output {
                    textOccurrences = detector.paths(
                        in: output,
                        maximumCount: Self.maximumDerivedPathCount
                    )
                }
            case .prose(let prose):
                textOccurrences = detector.paths(
                    in: prose.text,
                    maximumCount: Self.maximumDerivedPathCount
                )
            case .thought(let thought):
                textOccurrences = detector.paths(
                    in: thought.text,
                    maximumCount: Self.maximumDerivedPathCount
                )
            case .terminal(let terminal):
                textOccurrences = detector.paths(
                    in: terminal.command,
                    maximumCount: Self.maximumDerivedPathCount
                )
                if let output = terminal.output {
                    let remaining = Self.maximumDerivedPathCount - textOccurrences.count
                    if remaining > 0 {
                        textOccurrences.append(contentsOf: detector.paths(
                            in: output,
                            maximumCount: remaining
                        ))
                    }
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
                    into: &byPath,
                    maximumPathCount: Self.maximumDerivedPathCount
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
                    into: &byPath,
                    maximumPathCount: Self.maximumDerivedPathCount
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
                into: &byPath,
                maximumPathCount: Self.maximumDerivedPathCount
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
        into byPath: inout [String: ChatArtifactIndexedReference],
        maximumPathCount: Int
    ) {
        let canonicalPath: String
        if let cached = canonicalPathByLexicalPath[path] {
            canonicalPath = cached
        } else {
            let resolvedPath = canonicalizer.canonicalPathKey(for: path)
            guard byPath[resolvedPath] != nil || byPath.count < maximumPathCount else {
                return
            }
            if canonicalPathByLexicalPath.count < Self.maximumCanonicalAliasCount {
                canonicalPathByLexicalPath[path] = resolvedPath
            }
            canonicalPath = resolvedPath
        }
        let previous = byPath[canonicalPath]
        let candidateAuthorization = provenance.captureAuthorization(sequence: seq)
        let captureAuthorization: ChatArtifactCaptureAuthorization?
        if let previousAuthorization = previous?.captureAuthorization,
           let candidateAuthorization {
            captureAuthorization = previousAuthorization.latest(with: candidateAuthorization)
        } else {
            captureAuthorization = previous?.captureAuthorization ?? candidateAuthorization
        }
        byPath[canonicalPath] = ChatArtifactIndexedReference(
            path: canonicalPath,
            provenance: previous?.provenance.preferred(over: provenance) ?? provenance,
            lastReferencedSeq: max(previous?.lastReferencedSeq ?? Int.min, seq),
            captureAuthorization: captureAuthorization
        )
    }
}
