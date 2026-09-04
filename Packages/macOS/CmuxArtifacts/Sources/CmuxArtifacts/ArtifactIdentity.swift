import CryptoKit
import Foundation

/// Produces canonical deduplication keys for every supported artifact kind.
public struct ArtifactIdentity: Sendable {
    /// Creates a canonical identity builder.
    public init() {}

    /// Canonicalizes an HTTP(S) URL without performing network I/O.
    public func canonicalURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        components?.host = host
        if (scheme == "http" && url.port == 80) || (scheme == "https" && url.port == 443) {
            components?.port = nil
        }
        guard let canonical = components?.url?.absoluteString else { return nil }
        return canonical
    }

    /// Returns the identity key for a URL, path, or content digest.
    public func key(
        kind: ArtifactKind,
        value: String,
        ownership: ArtifactOwnership? = nil
    ) -> String {
        let base: String
        switch kind {
        case .url:
            if let url = URL(string: value), url.isFileURL {
                base = "path:url:\(canonicalPath(url.path))"
            } else {
                base = "url:\(canonicalURL(value) ?? value.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        case .directory:
            base = "directory:\(canonicalPath(value))"
        case .file, .image, .pdf, .audio, .video, .browserDownload, .generated:
            base = "path:\(kind.rawValue):\(canonicalPath(value))"
        case .html, .text, .code, .json, .manual:
            base = "content:\(kind.rawValue):\(stableTextDigest(value))"
        case .unknown:
            base = "content:\(kind.rawValue):\(stableTextDigest(value))"
        }
        return scoped(base, ownership: ownership)
    }

    /// Returns a content-addressed identity for bytes supplied without a source path.
    public func contentKey(
        kind: ArtifactKind,
        digest: String,
        ownership: ArtifactOwnership? = nil
    ) -> String {
        scoped("content:\(kind.rawValue):\(digest.lowercased())", ownership: ownership)
    }

    /// Returns a normalized absolute path without touching the filesystem.
    public func canonicalPath(_ value: String) -> String {
        URL(fileURLWithPath: value)
            .standardizedFileURL
            .path
    }

    /// Returns a deterministic SHA-256 hex identity for a bounded inline value.
    public func stableTextDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { byte in
                let high = String(byte >> 4, radix: 16)
                let low = String(byte & 0x0F, radix: 16)
                return high + low
            }
            .joined()
    }

    private func scoped(_ base: String, ownership: ArtifactOwnership?) -> String {
        guard let ownership else { return base }
        let workspace = ownership.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = ownership.projectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !workspace.isEmpty || !project.isEmpty else { return base }
        // Scope is part of the dedupe key. A URL or digest observed in two
        // workspaces must remain two attributable records in the global view;
        // otherwise the first workspace would silently own the second one's
        // history.
        return "\(base)|workspace=\(workspace)|project=\(project)"
    }
}
