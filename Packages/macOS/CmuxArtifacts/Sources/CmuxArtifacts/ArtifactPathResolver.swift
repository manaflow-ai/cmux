import Foundation

/// Pure path policy for ephemeral detection, grouping, and confinement.
struct ArtifactPathResolver: Sendable {
    static let workspaceMarkerName = "_workspace.json"
    static let sessionMarkerName = "_session.json"

    func isEphemeral(_ url: URL, prefixes: [String], temporaryDirectory: URL) -> Bool {
        let path = canonicalPath(url)
        let temporary = canonicalPath(temporaryDirectory)
        return prefixes.contains {
            contains(
                path: path,
                under: canonicalPath(URL(fileURLWithPath: $0, isDirectory: true))
            )
        }
            || contains(path: path, under: temporary)
    }

    func isInsideStore(_ url: URL, paths: ArtifactStorePaths) -> Bool {
        contains(
            path: canonicalPath(url),
            under: canonicalPath(paths.artifactsRoot)
        )
    }

    func relativePath(_ url: URL, root: URL) -> String? {
        let path = canonicalPath(url)
        let rootPath = canonicalPath(root)
        guard contains(path: path, under: rootPath), path != rootPath else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    func refersToSameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    func captureDirectory(paths: ArtifactStorePaths, context: ArtifactCaptureContext) -> URL {
        let workspace = slug(
            preferred: context.workspaceTitle,
            fallbackPrefix: "workspace",
            identity: context.workspaceID
        )
        let sessionPrefix = normalized(context.agentName) ?? "session"
        let session = slug(
            preferred: nil,
            fallbackPrefix: sessionPrefix,
            identity: context.sessionID
        )
        return paths.artifactsRoot
            .appendingPathComponent(workspace, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
    }

    func slug(preferred: String?, fallbackPrefix: String, identity: String?) -> String {
        let preferredSlug = normalized(preferred)
        let identitySlug = normalized(identity).map { String($0.prefix(16)) }
        if let preferredSlug, let identitySlug {
            return "\(String(preferredSlug.prefix(48)))-\(identitySlug)"
        }
        if let preferredSlug { return String(preferredSlug.prefix(64)) }
        if let identitySlug { return "\(fallbackPrefix)-\(identitySlug)" }
        return fallbackPrefix
    }

    func uniqueDestination(
        source: URL,
        directory: URL,
        fileManager: FileManager,
        reservedPaths: Set<String> = []
    ) -> URL {
        let proposed = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        let usesCaseSensitiveNames = volumeSupportsCaseSensitiveNames(
            at: directory,
            fileManager: fileManager
        ) == true
        let isSessionMarkerName: (String) -> Bool = { name in
            if usesCaseSensitiveNames { return name == Self.sessionMarkerName }
            return name.caseInsensitiveCompare(Self.sessionMarkerName) == .orderedSame
        }
        guard fileManager.fileExists(atPath: proposed.path)
                || reservedPaths.contains(proposed.standardizedFileURL.path)
                || isSessionMarkerName(proposed.lastPathComponent) else {
            return proposed
        }
        let basename = source.deletingPathExtension().lastPathComponent
        let pathExtension = source.pathExtension
        for suffix in 2...10_000 {
            var name = "\(basename)-\(suffix)"
            if !pathExtension.isEmpty { name += ".\(pathExtension)" }
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path),
               !reservedPaths.contains(candidate.standardizedFileURL.path),
               !isSessionMarkerName(candidate.lastPathComponent) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
    }

    private func volumeSupportsCaseSensitiveNames(
        at url: URL,
        fileManager: FileManager
    ) -> Bool? {
        for ancestor in ArtifactAncestorDirectories(startingAt: url) {
            guard fileManager.fileExists(atPath: ancestor.path),
                  let values = try? ancestor.resourceValues(
                      forKeys: [.volumeSupportsCaseSensitiveNamesKey]
                  ),
                  let supportsCaseSensitiveNames = values.volumeSupportsCaseSensitiveNames else {
                continue
            }
            return supportsCaseSensitiveNames
        }
        return nil
    }

    private func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let scalars = raw.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let value = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return value.isEmpty ? nil : value
    }

    private func contains(path: String, under root: String) -> Bool {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        for ancestor in ArtifactAncestorDirectories(startingAt: standardized) {
            guard FileManager.default.fileExists(atPath: ancestor.path) else { continue }
            let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
            let unresolvedComponents = standardized.pathComponents.dropFirst(ancestor.pathComponents.count)
            return unresolvedComponents.reduce(resolvedAncestor) { partialURL, component in
                partialURL.appendingPathComponent(component, isDirectory: false)
            }
            .standardizedFileURL.path
        }
        return standardized.path
    }
}
