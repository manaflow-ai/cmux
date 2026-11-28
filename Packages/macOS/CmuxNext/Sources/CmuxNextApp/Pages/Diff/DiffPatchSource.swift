import CmuxNextPages
import Darwin
import Foundation

/// Which file `cmux-page://cmux.diff/__patch/<token>/<path>` names, by the rules
/// the classic `cmux-diff-viewer://` handler and the sidecar's manifest use
/// (Native/DiffSidecar/src/manifest.rs):
/// - the token is this tab's own (one tab never reads another's patches);
/// - `/<path>` is a request path the token's manifest lists, a local
///   `text/x-diff` `.patch` entry (no remote URL);
/// - the entry's file, with every symlink resolved, is a regular file inside
///   the resolved session root, compared by path components.
/// Blocking file IO: call it off the main actor.
nonisolated struct DiffPatchResolver: Sendable {
    let root: URL
    let token: String

    static let prefix = "__patch"
    static let mimeType = "text/x-diff"
    static let maximumManifestBytes = 4 * 1024 * 1024
    static let maximumFiles = 4096
    /// The sidecar's own patch limit (MAX_SESSION_PATCH_BYTES).
    static let maximumPatchBytes = 512 * 1024 * 1024

    /// The sidecar's `valid_token`: 16 to 80 ASCII letters, digits and dashes.
    static func isValidToken(_ token: String) -> Bool {
        (16...80).contains(token.utf8.count) && token.utf8.allSatisfy { $0 == UInt8(ascii: "-") || isAlphanumeric($0) }
    }

    /// The sidecar's `valid_request_path` for `/` + `components`.
    static func requestPath(_ components: [String]) -> String? {
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") })
        else { return nil }
        return "/" + components.joined(separator: "/")
    }

    /// The patch file of `request`, nil for anything the rules above refuse.
    func file(for request: PageResourceRequest) -> URL? {
        guard request.prefix == Self.prefix, let first = request.path.first, first == token, Self.isValidToken(token),
              let path = Self.requestPath(Array(request.path.dropFirst())), path.hasSuffix(".patch"),
              let entry = entries()?.first(where: { $0.requestPath == path }),
              entry.mimeType == Self.mimeType, entry.remote == false else { return nil }
        return contained(entry.filePath)
    }

    /// The local files the manifest lists inside the root (for cleanup).
    func listedFiles() -> [URL] {
        (entries() ?? []).filter { !$0.remote }.compactMap { contained($0.filePath) }
    }

    private struct Entry {
        let requestPath: String
        let filePath: String
        let mimeType: String
        let remote: Bool
    }

    private func entries() -> [Entry]? {
        guard Self.isValidToken(token) else { return nil }
        let url = root.appending(path: ".manifest-\(token).json")
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Int64(Self.maximumManifestBytes),
              // concurrency-allow: nonisolated resolver; DiffPatchSource calls it from a @concurrent read
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["token"] as? String == token,
              let files = object["files"] as? [[String: Any]], files.count <= Self.maximumFiles else { return nil }
        return files.compactMap { file in
            guard let path = file["request_path"] as? String, let filePath = file["file_path"] as? String,
                  let mime = file["mime_type"] as? String else { return nil }
            let remote = !(file["remote_url"] == nil || file["remote_url"] is NSNull)
            return Entry(requestPath: path, filePath: filePath, mimeType: mime, remote: remote)
        }
    }

    /// `path` resolved, when it is a regular file strictly inside the resolved root.
    private func contained(_ path: String) -> URL? {
        guard !path.isEmpty, let rootPath = Self.realPath(root.path), let filePath = Self.realPath(path) else { return nil }
        let rootComponents = URL(fileURLWithPath: rootPath).pathComponents
        let fileComponents = URL(fileURLWithPath: filePath).pathComponents
        guard fileComponents.count > rootComponents.count, Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        var info = stat()
        guard stat(filePath, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Int64(Self.maximumPatchBytes) else { return nil }
        return URL(fileURLWithPath: filePath)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
}

/// The diff page's `__patch/` prefix (diff-host.md decision c): serves one
/// tab's patches through ``DiffPatchResolver`` with that tab's current grant,
/// read off the main actor, with the sidecar's MIME type. Nothing is served
/// while the tab has no grant. The tab's page view keeps it alive.
final class DiffPatchSource: PageDynamicResourceSource {
    private let current: () -> Task<DiffTabReady, any Error>?

    /// `current` is the tab's grant now (its provider's).
    init(current: @escaping () -> Task<DiffTabReady, any Error>?) {
        self.current = current
    }

    convenience init(ready: Task<DiffTabReady, any Error>) {
        self.init { ready }
    }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard let grant = try? await current()?.value.grant else { return nil }
        return await Self.read(DiffPatchResolver(root: grant.root, token: grant.token), request)
    }

    @concurrent private static func read(_ resolver: DiffPatchResolver, _ request: PageResourceRequest) async -> PageResource? {
        // concurrency-allow: @concurrent, so this mapped read never runs on the main actor
        guard let file = resolver.file(for: request), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return PageResource(data: data, mimeType: DiffPatchResolver.mimeType + "; charset=utf-8")
    }
}
