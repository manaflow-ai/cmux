import Darwin
public import Foundation

/// Limits every path a page frame names (`params.cwd`, `params.path`) to the pane's workspace
/// roots, the folders the Swift host knows for this pane (origin lead rule): the path is made
/// canonical first (`realpath`: absolute, existing, symlinks and `..` resolved), then checked
/// against each canonical root by path components, never by string prefix. A canonical path is
/// what the daemon receives. Anything else is refused with a typed error. The daemon checks again
/// (an existing canonical directory; a preset's pinned cwd wins), in its own lane.
public nonisolated enum AcpmuxPathPolicy {
    /// The params a page frame may name a folder in, at any depth (C1): each value is a path or a
    /// list of paths. Every one of them must be a directory, except `path`, which may be a file.
    public static let keys = ["cwd", "path", "additionalDirectories", "directory", "directories", "workingDirectory",
                              "folder", "folders", "root", "roots", "worktree", "worktreePath"]

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

    static func checkNow(_ text: String, roots: [String]) -> Result<String, Refusal> {
        // Parsed every time: a substring test would miss an escaped key ("c\u0077d").
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let params = object["params"] else { return .success(text) }
        let method = object["method"] as? String
        let id = object["id"].flatMap(AcpmuxPaneMethods.rawID)
        let canonicalRoots = roots.compactMap(canonical).filter { $0 != "/" }
        var changed = false
        let checked: Any
        do {
            checked = try rewrite(params, roots: canonicalRoots, changed: &changed)
        } catch let error as AgentPaneTransportError {
            return .failure(Refusal(error: error, requestID: id, method: method))
        } catch {
            return .failure(Refusal(error: .invalidFrame, requestID: id, method: method))
        }
        guard changed else { return .success(text) }
        object["params"] = checked
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return .failure(Refusal(error: .invalidFrame, requestID: id, method: method))
        }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// `value` with every folder field made canonical; throws the refusal of the first bad one.
    static func rewrite(_ value: Any, roots: [String], changed: inout Bool) throws -> Any {
        if var object = value as? [String: Any] {
            for (key, inner) in object {
                if keys.contains(key) {
                    object[key] = try folder(inner, key: key, roots: roots)
                    changed = true
                } else {
                    object[key] = try rewrite(inner, roots: roots, changed: &changed)
                }
            }
            return object
        }
        if let list = value as? [Any] { return try list.map { try rewrite($0, roots: roots, changed: &changed) } }
        return value
    }

    /// One folder field's value (a path, or a list of paths), canonical and inside a root.
    static func folder(_ value: Any, key: String, roots: [String]) throws -> Any {
        if let list = value as? [Any] { return try list.map { try folder($0, key: key, roots: roots) } }
        guard let path = value as? String, let resolved = canonical(path),
              key == "path" || isDirectory(resolved) else { throw AgentPaneTransportError.pathInvalid }
        guard roots.contains(where: { contains(root: $0, path: resolved) }) else { throw AgentPaneTransportError.pathOutsideRoots }
        return resolved
    }

    /// The canonical form of an absolute path that exists, nil otherwise: `realpath` (symlinks and
    /// `..` resolved), then each component in the filesystem's own spelling (APFS is case- and
    /// normalization-insensitive and realpath keeps the typed spelling), then NFC. Off the main
    /// actor (``check(_:roots:)``): it touches the disk.
    public static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        var spelled = ""
        for component in real.split(separator: "/", omittingEmptySubsequences: true) {
            let typed = spelled + "/" + component
            guard let stored = storedName(typed) else { return nil }
            spelled += "/" + stored
        }
        return (spelled.isEmpty ? "/" : spelled).precomposedStringWithCanonicalMapping
    }

    /// The name the filesystem stores for the last component of `path` (`getattrlist`
    /// `ATTR_CMN_NAME`, not following a final link: realpath already resolved them).
    static func storedName(_ path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_NAME)
        var buffer = [UInt8](repeating: 0, count: 4 + 8 + Int(NAME_MAX) * 3 + 1)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            // u_int32_t length, then attrreference_t {int32 offset (from the reference), u_int32 length}.
            let reference = 4
            let offset = Int(raw.loadUnaligned(fromByteOffset: reference, as: Int32.self))
            let length = Int(raw.loadUnaligned(fromByteOffset: reference + 4, as: UInt32.self))
            let start = reference + offset
            guard length > 1, start >= 0, start + length <= raw.count else { return nil }
            return String(decoding: raw[start..<(start + length - 1)], as: UTF8.self) // length counts the NUL
        }
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
