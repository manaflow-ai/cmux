import Foundation

extension LocalArtifactRepository {
    struct PreparedInput: Sendable {
        let kind: ArtifactKind
        let identityKey: String
        let representation: ArtifactRepresentation
        let metadata: [String: String]
    }

    func prepare(
        _ request: ArtifactIngestRequest,
        capturedAt: Date
    ) throws -> PreparedInput {
        var metadata = request.metadata
        switch request.input {
        case .url(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme) else {
                throw ArtifactStoreError.unsupportedKind("url")
            }
            if scheme == "file" {
                guard configuration.includeFilePaths || request.authorization == .explicitUser else {
                    throw ArtifactStoreError.unsupportedKind("file URL capture disabled")
                }
                return try prepareFile(
                    URL(fileURLWithPath: url.path),
                    requestedKind: request.kind,
                    source: request.source,
                    authorization: request.authorization,
                    ownership: request.ownership,
                    metadata: metadata
                )
            }
            guard let canonical = identity.canonicalURL(trimmed), !isIgnoredHost(canonical) else {
                throw ArtifactStoreError.unsupportedKind("ignored or invalid host")
            }
            metadata["url"] = canonical
            return PreparedInput(
                kind: request.kind ?? .url,
                identityKey: identity.key(kind: .url, value: canonical, ownership: request.ownership),
                representation: .url(canonical),
                metadata: metadata
            )
        case .html(let html):
            let bounded = try boundedInline(html, kind: .html)
            metadata["contentType"] = metadata["contentType"] ?? "text/html"
            return PreparedInput(
                kind: request.kind ?? .html,
                identityKey: identity.key(kind: request.kind ?? .html, value: bounded, ownership: request.ownership),
                representation: .inlineHTML(bounded),
                metadata: metadata
            )
        case .text(let text):
            let kind = request.kind ?? inferredTextKind(metadata: metadata)
            guard kind.isTextSearchable else { throw ArtifactStoreError.unsupportedKind(kind.rawValue) }
            let bounded = try boundedInline(text, kind: kind)
            return PreparedInput(
                kind: kind,
                identityKey: identity.key(kind: kind, value: bounded, ownership: request.ownership),
                representation: .inlineText(bounded),
                metadata: metadata
            )
        case .file(let url):
            return try prepareFile(
                url,
                requestedKind: request.kind,
                source: request.source,
                authorization: request.authorization,
                ownership: request.ownership,
                metadata: metadata
            )
        case .directory(let url):
            let canonical = try authorizePath(
                url,
                authorization: request.authorization,
                ownership: request.ownership,
                requireDirectory: true
            )
            let kind = request.kind ?? .directory
            metadata["path"] = canonical.path
            return PreparedInput(
                kind: kind,
                identityKey: identity.key(kind: .directory, value: canonical.path, ownership: request.ownership),
                representation: .directory(path: canonical.path),
                metadata: metadata
            )
        case .data(let data, let fileName, let mimeType):
            let kind = request.kind ?? ArtifactKind(
                pathExtension: URL(fileURLWithPath: fileName).pathExtension,
                mimeType: mimeType
            )
            guard Int64(data.count) <= configuration.maximumFileBytes else {
                throw ArtifactStoreError.fileTooLarge(
                    actual: Int64(data.count),
                    limit: configuration.maximumFileBytes
                )
            }
            let digest = ArtifactDigest(fileManager: fileManager).digest(data: data)
            let relativePath = try writePayload(data: data, fileName: fileName, digest: digest)
            metadata["fileName"] = fileName
            if let mimeType { metadata["mimeType"] = mimeType }
            return PreparedInput(
                kind: kind,
                identityKey: identity.contentKey(kind: kind, digest: digest, ownership: request.ownership),
                representation: .managedFile(relativePath: relativePath, suggestedFileName: safeFileName(fileName)),
                metadata: metadata
            )
        }
    }

    private func prepareFile(
        _ url: URL,
        requestedKind: ArtifactKind?,
        source: ArtifactSource,
        authorization: ArtifactCaptureAuthorization,
        ownership: ArtifactOwnership,
        metadata: [String: String]
    ) throws -> PreparedInput {
        let canonical = try authorizePath(
            url,
            authorization: authorization,
            ownership: ownership,
            requireDirectory: false
        )
        let (digest, data) = try ArtifactDigest(fileManager: fileManager).digest(
            url: canonical,
            maximumBytes: configuration.maximumFileBytes
        )
        let inferred = requestedKind ?? ArtifactKind(pathExtension: canonical.pathExtension)
        let relativePath = try writePayload(data: data, fileName: canonical.lastPathComponent, digest: digest)
        var enriched = metadata
        enriched["sourcePath"] = canonical.path
        enriched["fileName"] = canonical.lastPathComponent
        enriched["source"] = source.rawValue
        if inferred.isTextSearchable,
           let text = String(data: Data(data.prefix(configuration.maximumIndexedContentBytes)), encoding: .utf8),
           !text.isEmpty {
            enriched["contentPreview"] = text
        }
        return PreparedInput(
            kind: inferred,
            // Content identity makes a moved/renamed file the same artifact,
            // while changed bytes become a new revision. The original path is
            // retained only as bounded provenance metadata.
            identityKey: identity.contentKey(kind: inferred, digest: digest, ownership: ownership),
            representation: .managedFile(
                relativePath: relativePath,
                suggestedFileName: safeFileName(canonical.lastPathComponent)
            ),
            metadata: enriched
        )
    }

    private func authorizePath(
        _ sourceURL: URL,
        authorization: ArtifactCaptureAuthorization,
        ownership: ArtifactOwnership,
        requireDirectory: Bool
    ) throws -> URL {
        guard !pathPolicy.hasFinalSymlink(sourceURL) else {
            throw ArtifactStoreError.unauthorizedPath(sourceURL.path)
        }
        let canonical = pathPolicy.canonicalURL(sourceURL)
        guard fileManager.fileExists(atPath: canonical.path) else {
            throw ArtifactStoreError.sourceUnavailable(sourceURL.path)
        }
        guard !isSymlink(canonical) else { throw ArtifactStoreError.unauthorizedPath(sourceURL.path) }
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if requireDirectory {
            guard values.isDirectory == true else { throw ArtifactStoreError.sourceUnavailable(canonical.path) }
        } else {
            guard values.isRegularFile == true else { throw ArtifactStoreError.sourceUnavailable(canonical.path) }
        }
        guard !pathPolicy.isSensitive(canonical) else {
            throw ArtifactStoreError.sensitivePath(canonical.path)
        }
        if case .automatic(let allowedRoots) = authorization {
            let roots = allowedRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
            guard pathPolicy.isContained(canonical, in: roots) else {
                throw ArtifactStoreError.unauthorizedPath(canonical.path)
            }
            if let projectRoot = ownership.projectRoot {
                let projectURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
                guard pathPolicy.isContained(canonical, in: [projectURL]) else {
                    throw ArtifactStoreError.unauthorizedPath(canonical.path)
                }
            }
        }
        if let size = values.fileSize, Int64(size) > configuration.maximumFileBytes, !requireDirectory {
            throw ArtifactStoreError.fileTooLarge(actual: Int64(size), limit: configuration.maximumFileBytes)
        }
        return canonical
    }

    private func boundedInline(_ value: String, kind: ArtifactKind) throws -> String {
        let data = Data(value.utf8)
        guard data.count <= configuration.maximumInlineBytes else {
            throw ArtifactStoreError.fileTooLarge(
                actual: Int64(data.count),
                limit: Int64(configuration.maximumInlineBytes)
            )
        }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ArtifactStoreError.unsupportedKind(kind.rawValue)
        }
        return value
    }

    private func inferredTextKind(metadata: [String: String]) -> ArtifactKind {
        let contentType = metadata["contentType"]?.lowercased() ?? ""
        if contentType == "application/json" || contentType == "application/ld+json" { return .json }
        if metadata["language"]?.isEmpty == false { return .code }
        return .text
    }

    private func isIgnoredHost(_ canonicalURL: String) -> Bool {
        guard let host = URL(string: canonicalURL)?.host?.lowercased() else { return false }
        return configuration.ignoreHosts.contains { pattern in
            if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
            return host == pattern || host.hasPrefix(pattern + ":")
        }
    }

    private func writePayload(data: Data, fileName: String, digest: String) throws -> String {
        try prepareDirectories()
        let ext = URL(fileURLWithPath: safeFileName(fileName)).pathExtension
        let baseName = digest + (ext.isEmpty ? "" : ".\(ext.lowercased())")
        let url = paths.payloads.appendingPathComponent(baseName, isDirectory: false)
        guard paths.contains(url), !isSymlink(url) else { throw ArtifactStoreError.unauthorizedPath(url.path) }
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: Data.WritingOptions.atomic)
        }
        return baseName
    }

    private func safeFileName(_ raw: String) -> String {
        let name = URL(fileURLWithPath: raw).lastPathComponent
        let bounded = String(name.prefix(128))
        return bounded.isEmpty ? "artifact" : bounded
    }
}
