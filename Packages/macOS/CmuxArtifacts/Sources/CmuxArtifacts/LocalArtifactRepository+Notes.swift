import Darwin
public import Foundation

extension LocalArtifactRepository: NoteStoring {
    private static var maximumNoteBytes: Int64 { 4 * 1024 * 1024 }

    /// Lists Markdown notes from every live session `notes` directory.
    public func listNotes(projectRoot: URL) throws -> [CmuxProjectNote] {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        try prepare(paths: paths)
        return CmuxProjectNoteResolver().notes(snapshot: try completeSnapshot(paths: paths))
    }

    /// Resolves a live note after arbitrary file or session-folder moves.
    public func resolveNote(projectRoot: URL, name: String) throws -> CmuxProjectNote {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        try prepare(paths: paths)
        return try CmuxProjectNoteResolver().resolve(
            snapshot: completeSnapshot(paths: paths),
            rawName: name
        )
    }

    /// Reads one bounded UTF-8 note without following symbolic links.
    public func readNote(projectRoot: URL, name: String) throws -> String {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        let note = try resolveNote(projectRoot: projectRoot, name: name)
        return try noteText(note, paths: paths)
    }

    /// Writes or appends one bounded UTF-8 note under the current session.
    public func writeNote(
        name: String,
        text: String,
        mode: CmuxNoteWriteMode,
        context: ArtifactCaptureContext
    ) throws -> CmuxProjectNote {
        let incoming = Data(text.utf8)
        guard incoming.count <= Self.maximumNoteBytes else {
            throw CmuxNoteStoreError.noteTooLarge(
                actual: Int64(incoming.count),
                limit: Self.maximumNoteBytes
            )
        }
        let paths = ArtifactStorePaths(projectRoot: context.projectRoot)
        try prepare(paths: paths)
        let lease = try ArtifactStoreMutationLease.acquire(directory: paths.filesystemRoot)
        defer { lease.finish() }

        let resolver = CmuxProjectNoteResolver()
        let snapshot = try completeSnapshot(paths: paths)
        let pathResolver = ArtifactPathResolver()
        let resolution = ArtifactCaptureDirectoryFinder(
            fileManager: fileManager,
            decoder: decoder,
            nodeBudget: nodeBudget
        ).resolve(
            paths: paths,
            context: context,
            pathResolver: pathResolver,
            kind: .notes
        )
        let rawName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let creationRelativePath = rawName.hasPrefix(".cmux/")
            ? nil
            : try resolver.creationRelativePath(rawName: name)
        let contentRelativePath = pathResolver.relativePath(
            resolution.directory,
            root: paths.filesystemRoot
        )
        let candidateNotes: [CmuxProjectNote]
        if rawName.hasPrefix(".cmux/") {
            candidateNotes = resolver.notes(snapshot: snapshot)
        } else if let contentRelativePath {
            let prefix = contentRelativePath + "/"
            candidateNotes = resolver.notes(snapshot: snapshot).filter {
                $0.relativePath.hasPrefix(prefix)
            }
        } else {
            candidateNotes = []
        }
        let existing: CmuxProjectNote?
        do {
            if let creationRelativePath,
               let contentRelativePath,
               let exact = candidateNotes.first(where: {
                   $0.relativePath == contentRelativePath + "/" + creationRelativePath
               }) {
                existing = exact
            } else {
                existing = try resolver.resolve(notes: candidateNotes, rawName: name)
            }
        } catch CmuxNoteStoreError.noteNotFound {
            existing = nil
        }

        let destination: URL
        if let existing {
            destination = URL(fileURLWithPath: existing.absolutePath, isDirectory: false)
        } else {
            guard let creationRelativePath else {
                throw CmuxNoteStoreError.noteNotFound(name)
            }
            try createCaptureDirectory(
                resolution.directory,
                paths: paths,
                context: context,
                capturedAt: now()
            )
            destination = resolution.directory.appendingPathComponent(creationRelativePath)
        }

        let parent = destination.deletingLastPathComponent()
        try rejectSymbolicLinks(from: paths.filesystemRoot, through: parent)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try rejectSymbolicLinks(from: paths.filesystemRoot, through: parent)

        let finalData: Data
        if mode == .append, let existing {
            let current = try noteData(existing, paths: paths)
            let combinedCount = current.count + incoming.count
            guard combinedCount <= Self.maximumNoteBytes else {
                throw CmuxNoteStoreError.noteTooLarge(
                    actual: Int64(combinedCount),
                    limit: Self.maximumNoteBytes
                )
            }
            var combined = current
            combined.append(incoming)
            finalData = combined
        } else {
            finalData = incoming
        }
        try CmuxNoteAtomicWriter().write(finalData, to: destination)

        guard let relativePath = pathResolver.relativePath(
            destination,
            root: paths.filesystemRoot
        ), let node = try ArtifactExactPathResolver().fileNode(
            relativePath: relativePath,
            paths: paths
        ) else {
            throw CmuxNoteStoreError.pathOutsideStore(destination.path)
        }
        return resolver.note(node)
    }

    /// Searches only live Markdown notes while sharing artifact search bounds.
    public func searchNotes(projectRoot: URL, query: String) throws -> [CmuxNoteSearchResult] {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        try prepare(paths: paths)
        let snapshot = try completeSnapshot(paths: paths)
        let resolver = CmuxProjectNoteResolver()
        let noteSnapshot = ArtifactSnapshot(
            projectRoot: snapshot.projectRoot,
            filesystemRoot: snapshot.filesystemRoot,
            nodes: resolver.noteNodes(snapshot: snapshot),
            isTruncated: false
        )
        return try ArtifactSearchEngine(configuration: configuration(projectRoot: projectRoot))
            .results(snapshot: noteSnapshot, query: query)
            .map { result in
                CmuxNoteSearchResult(
                    note: resolver.note(result.node),
                    matchedContent: result.matchedContent,
                    snippet: result.snippet
                )
            }
    }

    /// Deletes one resolved note without following a replaced symbolic link.
    public func deleteNote(projectRoot: URL, name: String) throws {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        try prepare(paths: paths)
        let lease = try ArtifactStoreMutationLease.acquire(directory: paths.filesystemRoot)
        defer { lease.finish() }
        let note = try CmuxProjectNoteResolver().resolve(
            snapshot: completeSnapshot(paths: paths),
            rawName: name
        )
        guard Darwin.unlink(note.absolutePath) == 0 else {
            throw CmuxNoteStoreError.pathOutsideStore(note.absolutePath)
        }
    }

    private func noteText(_ note: CmuxProjectNote, paths: ArtifactStorePaths) throws -> String {
        let data = try noteData(note, paths: paths)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CmuxNoteStoreError.invalidUTF8(note.relativePath)
        }
        return text
    }

    private func noteData(_ note: CmuxProjectNote, paths: ArtifactStorePaths) throws -> Data {
        if let size = note.size, size > Self.maximumNoteBytes {
            throw CmuxNoteStoreError.noteTooLarge(actual: size, limit: Self.maximumNoteBytes)
        }
        let url = URL(fileURLWithPath: note.absolutePath, isDirectory: false)
        guard let data = try ArtifactBoundedFileReader().data(
            url: url,
            allowedRoot: paths.filesystemRoot,
            maximumBytes: Self.maximumNoteBytes
        ) else {
            throw CmuxNoteStoreError.pathOutsideStore(note.absolutePath)
        }
        return data
    }
}
