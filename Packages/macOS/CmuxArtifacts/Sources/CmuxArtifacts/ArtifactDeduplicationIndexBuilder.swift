import Foundation

/// Builds one bounded digest-to-path index for a prepared import batch.
struct ArtifactDeduplicationIndexBuilder {
    let recorder: ArtifactProvenanceRecorder
    let scanner: ArtifactTreeScanner

    func build(
        prepared: [PreparedArtifactImport],
        paths: ArtifactStorePaths
    ) throws -> [String: URL] {
        let pathResolver = ArtifactPathResolver()
        var existingByDigest: [String: URL] = [:]
        var unresolvedBySize: [Int64: Set<String>] = [:]
        for item in prepared {
            let size = item.snapshot.size
            if let document = recorder.document(paths: paths, digest: item.digest),
               document.size == size {
                let lastKnownURL = paths.artifactsRoot
                    .appendingPathComponent(document.lastKnownRelativePath, isDirectory: false)
                if pathResolver.isInsideStore(lastKnownURL, paths: paths),
                   matches(file: lastKnownURL, digest: item.digest, size: size) {
                    existingByDigest[item.digest] = lastKnownURL
                    continue
                }
            }
            unresolvedBySize[size, default: []].insert(item.digest)
        }
        guard !unresolvedBySize.isEmpty else { return existingByDigest }
        for file in try scanner.files(paths: paths, matchingSizes: Set(unresolvedBySize.keys)) {
            guard let rawSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            let size = Int64(rawSize)
            guard let unresolvedDigests = unresolvedBySize[size], !unresolvedDigests.isEmpty,
                  let digest = try? ArtifactDigestCalculator().digest(url: file),
                  unresolvedDigests.contains(digest) else {
                continue
            }
            existingByDigest[digest] = file
            unresolvedBySize[size]?.remove(digest)
            if unresolvedBySize[size]?.isEmpty == true {
                unresolvedBySize.removeValue(forKey: size)
            }
            if unresolvedBySize.isEmpty { break }
        }
        return existingByDigest
    }

    private func matches(file: URL, digest: String, size: Int64) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        Int64(values.fileSize ?? -1) == size,
        let existingDigest = try? ArtifactDigestCalculator().digest(url: file) else {
            return false
        }
        return existingDigest == digest
    }
}
