import Darwin
public import Foundation

/// Limits every path a page frame names (`params.cwd`, `params.path`) to the pane's workspace
/// roots, the folders the Swift host knows for this pane (origin lead rule): the path is made
/// canonical first (`realpath`: absolute, existing, symlinks and `..` resolved), then checked
/// against each canonical root by path components, never by string prefix. A canonical path is
/// what the daemon receives. Anything else is refused with a typed error. The daemon checks again
/// (an existing canonical directory; a preset's pinned cwd wins), in its own lane.
public nonisolated enum AcpmuxPathPolicy {
    /// The params a page frame may name a path in.
    public static let keys = ["cwd", "path"]

    /// Why a path was refused, and the refused request's id (raw JSON) to answer it.
    public nonisolated struct Refusal: Error, Equatable, Sendable {
        public var error: AgentPaneTransportError
        public var requestID: String?
        public var method: String?
    }

    /// `text` with each path param canonical, or the refusal. Off the main actor: it touches the disk.
    @concurrent public static func check(_ text: String, roots: [String]) async -> Result<String, Refusal> {
        checkNow(text, roots: roots)
    }

    /// True when `text` may name a path (a cheap test before parsing).
    public static func mayNamePath(_ text: String) -> Bool {
        keys.contains { text.contains("\"\($0)\"") }
    }

    static func checkNow(_ text: String, roots: [String]) -> Result<String, Refusal> {
        if true { return .success(text) } // RED STUB: no workspace roots
        guard mayNamePath(text),
              var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              var params = object["params"] as? [String: Any],
              keys.contains(where: { params[$0] != nil }) else { return .success(text) }
        let method = object["method"] as? String
        let id = object["id"].flatMap(AcpmuxPaneMethods.rawID)
        let canonicalRoots = roots.compactMap(canonical).filter { $0 != "/" }
        for key in keys {
            guard let value = params[key] else { continue }
            guard let path = value as? String, let resolved = canonical(path),
                  key != "cwd" || isDirectory(resolved) else {
                return .failure(Refusal(error: .pathInvalid, requestID: id, method: method))
            }
            guard canonicalRoots.contains(where: { contains(root: $0, path: resolved) }) else {
                return .failure(Refusal(error: .pathOutsideRoots, requestID: id, method: method))
            }
            params[key] = resolved
        }
        object["params"] = params
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return .failure(Refusal(error: .invalidFrame, requestID: id, method: method))
        }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// The canonical form of an absolute path that exists; nil otherwise.
    public static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Whether canonical `path` is canonical `root` or under it, by components.
    static func contains(root: String, path: String) -> Bool {
        let rootParts = root.split(separator: "/", omittingEmptySubsequences: true)
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: true)
        return pathParts.count >= rootParts.count && zip(rootParts, pathParts).allSatisfy { $0 == $1 }
    }
}
