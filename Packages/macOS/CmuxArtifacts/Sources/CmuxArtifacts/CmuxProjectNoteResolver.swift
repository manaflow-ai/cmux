import Foundation

/// Pure live-tree projection and name resolution for cmux Notes.
struct CmuxProjectNoteResolver {
    private static let allowedExtensions: Set<String> = ["md", "markdown"]

    func notes(snapshot: ArtifactSnapshot) -> [CmuxProjectNote] {
        noteNodes(snapshot: snapshot)
            .map(note)
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    func noteNodes(snapshot: ArtifactSnapshot) -> [ArtifactNode] {
        snapshot.nodes.flattenedArtifactNodes().filter(isNoteNode)
    }

    func resolve(snapshot: ArtifactSnapshot, rawName: String) throws -> CmuxProjectNote {
        try resolve(notes: notes(snapshot: snapshot), rawName: rawName)
    }

    func resolve(notes: [CmuxProjectNote], rawName: String) throws -> CmuxProjectNote {
        let name = normalizedReference(rawName)
        guard !name.isEmpty else { throw CmuxNoteStoreError.invalidName(rawName) }
        if let exact = notes.first(where: { $0.relativePath == name }) { return exact }

        let requestedBasename = URL(fileURLWithPath: name).lastPathComponent
        let requestedStem = URL(fileURLWithPath: requestedBasename).deletingPathExtension().lastPathComponent
        let basenameMatches = notes.filter { candidate in
            candidate.name.caseInsensitiveCompare(requestedBasename) == .orderedSame
                || URL(fileURLWithPath: candidate.name)
                    .deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(requestedStem) == .orderedSame
        }
        if basenameMatches.count == 1, let match = basenameMatches.first { return match }
        if basenameMatches.count > 1 {
            throw CmuxNoteStoreError.ambiguousNoteName(
                rawName,
                matches: basenameMatches.map(\.relativePath)
            )
        }

        let matcher = ArtifactFuzzyMatcher(query: name)
        let matches = notes.compactMap { candidate in
            matcher.score(candidate: candidate.relativePath).map { (candidate, $0) }
        }.sorted { $0.1 > $1.1 }
        guard let best = matches.first else { throw CmuxNoteStoreError.noteNotFound(rawName) }
        if matches.count > 1, matches[1].1 == best.1 {
            throw CmuxNoteStoreError.ambiguousNoteName(
                rawName,
                matches: matches.filter { $0.1 == best.1 }.map { $0.0.relativePath }
            )
        }
        return best.0
    }

    func resolveExact(notes: [CmuxProjectNote], rawName: String) throws -> CmuxProjectNote {
        let name = normalizedReference(rawName)
        guard !name.isEmpty else { throw CmuxNoteStoreError.invalidName(rawName) }
        if let exact = notes.first(where: { $0.relativePath == name }) { return exact }
        guard !name.contains("/") else { throw CmuxNoteStoreError.noteNotFound(rawName) }

        let requestedBasename = URL(fileURLWithPath: name).lastPathComponent
        let requestedStem = URL(fileURLWithPath: requestedBasename)
            .deletingPathExtension().lastPathComponent
        let matches = notes.filter { candidate in
            candidate.name.caseInsensitiveCompare(requestedBasename) == .orderedSame
                || URL(fileURLWithPath: candidate.name)
                    .deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(requestedStem) == .orderedSame
        }
        guard matches.count <= 1 else {
            throw CmuxNoteStoreError.ambiguousNoteName(
                rawName,
                matches: matches.map(\.relativePath)
            )
        }
        guard let match = matches.first else {
            throw CmuxNoteStoreError.noteNotFound(rawName)
        }
        return match
    }

    func creationRelativePath(rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 1_024,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix(".cmux/"),
              !trimmed.contains("\0"),
              !trimmed.contains("\n") else {
            throw CmuxNoteStoreError.invalidName(rawName)
        }
        var components = trimmed.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CmuxNoteStoreError.invalidName(rawName)
        }
        let filename = components.removeLast()
        let url = URL(fileURLWithPath: filename)
        let pathExtension = url.pathExtension.lowercased()
        let finalName: String
        if pathExtension.isEmpty {
            finalName = filename + ".md"
        } else if Self.allowedExtensions.contains(pathExtension) {
            finalName = filename
        } else {
            throw CmuxNoteStoreError.invalidName(rawName)
        }
        guard !finalName.hasPrefix(".") else { throw CmuxNoteStoreError.invalidName(rawName) }
        components.append(finalName)
        return components.joined(separator: "/")
    }

    func note(_ node: ArtifactNode) -> CmuxProjectNote {
        CmuxProjectNote(
            name: node.name,
            relativePath: node.relativePath,
            absolutePath: node.absolutePath,
            size: node.size,
            modifiedAt: node.modifiedAt
        )
    }

    private func isNoteNode(_ node: ArtifactNode) -> Bool {
        guard !node.isDirectory,
              Self.allowedExtensions.contains(
                  URL(fileURLWithPath: node.name).pathExtension.lowercased()
              ) else { return false }
        let parentComponents = node.relativePath.split(separator: "/").dropLast()
        return parentComponents.contains("notes")
    }

    private func normalizedReference(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(".cmux/") ? String(trimmed.dropFirst(".cmux/".count)) : trimmed
    }
}
