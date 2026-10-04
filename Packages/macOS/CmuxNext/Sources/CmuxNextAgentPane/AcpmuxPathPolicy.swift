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
        /// The canonical path that is outside every root (the host may offer to add it).
        public var outsidePath: String? = nil

        public init(error: AgentPaneTransportError, requestID: String?, method: String?, outsidePath: String? = nil) {
            self.error = error
            self.requestID = requestID
            self.method = method
            self.outsidePath = outsidePath
        }

        public static func == (lhs: Refusal, rhs: Refusal) -> Bool {
            lhs.error == rhs.error && lhs.requestID == rhs.requestID && lhs.method == rhs.method
        }
    }

    /// The folders a pane's frames may name.
    public nonisolated struct Scope: Sendable {
        /// The host's own roots: the workspace's local tab folders, the handshake's cwd, the new
        /// tab page's cwd, and folders the user added or picked.
        public var roots: [String]
        /// Folders that are roots only when the user picked one by a gesture (the new tab page's
        /// project scan and open folders); a frame under one must use a gesture.
        public var gestureRoots: [String] = []
        /// The cwd a `session/new` (or adopt) without one gets (the pane's workspace root); nil
        /// refuses such a frame with `transport.path_invalid`.
        public var fillCwd: String? = nil

        public init(roots: [String], gestureRoots: [String] = [], fillCwd: String? = nil) {
            self.roots = roots
            self.gestureRoots = gestureRoots
            self.fillCwd = fillCwd
        }
    }

    /// A checked frame: its text with every folder canonical, and the gesture roots it used.
    public nonisolated struct Checked: Equatable, Sendable {
        public var text: String
        public var gestureRootsUsed: [String]
    }

    /// `text` checked against `scope`, or the refusal. Off the main actor: it touches the disk.
    @concurrent public static func check(_ text: String, scope: Scope) async -> Result<Checked, Refusal> {
        checkNow(text, scope: scope)
    }

    /// The frame with only trusted `roots` (tests and callers without a scope).
    static func checkNow(_ text: String, roots: [String]) -> Result<String, Refusal> {
        checkNow(text, scope: Scope(roots: roots)).map(\.text)
    }

    static func checkNow(_ text: String, scope: Scope) -> Result<Checked, Refusal> {
        // Parsed every time: a substring test would miss an escaped key ("c\u0077d").
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .success(Checked(text: text, gestureRootsUsed: []))
        }
        let method = object["method"] as? String
        let id = object["id"].flatMap(AcpmuxPaneMethods.rawID)
        var context = Context(roots: scope.roots.compactMap(canonical).filter { $0 != "/" },
                              gestureRoots: scope.gestureRoots.compactMap(canonical).filter { $0 != "/" })
        var params = object["params"]
        // Product rule 1: session/new (adopt too) without a cwd gets the pane's workspace root.
        if false, method == "session/new" { // RED STUB: no cwd fill
            var fields = params as? [String: Any] ?? [:]
            if fields["cwd"] == nil {
                guard let fill = scope.fillCwd else { return .failure(Refusal(error: .pathInvalid, requestID: id, method: method)) }
                fields["cwd"] = fill
                context.changed = true
            }
            params = fields
        }
        guard let params else { return .success(Checked(text: text, gestureRootsUsed: [])) }
        let checked: Any
        do {
            checked = try rewrite(params, context: &context)
        } catch let refusal as Refusal {
            return .failure(Refusal(error: refusal.error, requestID: id, method: method, outsidePath: refusal.outsidePath))
        } catch {
            return .failure(Refusal(error: .invalidFrame, requestID: id, method: method))
        }
        let used = Array(context.used)
        guard context.changed else { return .success(Checked(text: text, gestureRootsUsed: used)) }
        object["params"] = checked
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return .failure(Refusal(error: .invalidFrame, requestID: id, method: method))
        }
        return .success(Checked(text: String(decoding: data, as: UTF8.self), gestureRootsUsed: used))
    }

    struct Context {
        var roots: [String]
        var gestureRoots: [String]
        var changed = false
        var used: Set<String> = []
    }

    /// `value` with every folder field made canonical; throws the refusal of the first bad one.
    static func rewrite(_ value: Any, context: inout Context) throws -> Any {
        if var object = value as? [String: Any] {
            for (key, inner) in object {
                if keys.contains(key) {
                    object[key] = try folder(inner, key: key, context: &context)
                    context.changed = true
                } else {
                    object[key] = try rewrite(inner, context: &context)
                }
            }
            return object
        }
        if let list = value as? [Any] { return try list.map { try rewrite($0, context: &context) } }
        return value
    }

    /// One folder field's value (a path, or a list of paths), canonical and inside a root.
    static func folder(_ value: Any, key: String, context: inout Context) throws -> Any {
        if let list = value as? [Any] { return try list.map { try folder($0, key: key, context: &context) } }
        guard let path = value as? String, let resolved = canonical(path), key == "path" || isDirectory(resolved) else {
            throw Refusal(error: .pathInvalid, requestID: nil, method: nil)
        }
        if context.roots.contains(where: { contains(root: $0, path: resolved) }) { return resolved }
        if let root = context.gestureRoots.first(where: { contains(root: $0, path: resolved) }) {
            _ = root // RED STUB: a scanned folder counts as a root
            return resolved
        }
        throw Refusal(error: .pathOutsideRoots, requestID: nil, method: nil, outsidePath: resolved)
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
