import Darwin
public import Foundation

/// `turn.undo {files: [{path, before, after}], apply}` from the edited-files card: puts each file
/// back to the turn's first content (`before`; null when the turn created the file) only while it
/// still holds exactly the turn's last content (`after`). Never through git, never through the
/// agent. With `apply` false it only says what would happen.
///
/// Rules (the host checks them, not the page): each request spends the pane's GRANT credit (a real
/// click or key, ``AgentPaneUserGestures/consume()``); every path is canonical (symlinks resolved
/// for its folder) and inside the pane's roots; the file itself is a regular file, never a
/// symlink and has no second name (a hard link); its bytes equal `after` exactly, read again right
/// before the write; every step after the folder check is relative to one descriptor of the
/// folder; the write is a temporary file in that folder with the original's permission bits,
/// extended attributes and ACL, renamed over the file; a file the turn created goes to the Trash.
/// A file over ``maximumTextBytes`` cannot be undone. A file that fails a rule keeps its bytes.
public nonisolated struct AgentPaneTurnUndo: Equatable, Sendable, CustomStringConvertible {
    public struct File: Equatable, Sendable {
        public var path: String
        /// The turn's first content of the file; nil when the turn created it.
        public var before: String?
        /// The turn's last content of the file.
        public var after: String
    }

    public var files: [File]
    public var apply: Bool

    /// The most files in one request, and the longest text of one side.
    public static let maximumFiles = 200
    public static let maximumTextBytes = 8 << 20

    /// What the host did (or, in a dry run, would do) with one file.
    public enum Status: String, Sendable {
        case reverted, trashed, wouldRevert, wouldTrash
        /// The file's bytes are not the turn's last content: the user or a later turn changed it.
        case changed
        /// A symlink, a folder, a missing or unreadable file, or a failed write.
        case cannotUndo
        /// The path is outside every root of the pane.
        case outsideRoots
    }

    /// Nil unless the params are exactly `files` (1 to ``maximumFiles`` entries of exactly
    /// `path`, `before`, `after`) and `apply` (a boolean): ``AgentPaneRequest/invalidTurnUndo``.
    init?(params: [String: Any]?) {
        guard let params, Set(params.keys) == ["files", "apply"],
              let apply = params["apply"] as? NSNumber, CFGetTypeID(apply) == CFBooleanGetTypeID(),
              let list = params["files"] as? [Any], list.count <= Self.maximumFiles else { return nil }
        var files: [File] = []
        for entry in list {
            guard let file = entry as? [String: Any], Set(file.keys) == ["path", "before", "after"],
                  let path = file["path"] as? String, path.hasPrefix("/"), !path.utf8.contains(0),
                  let after = file["after"] as? String, after.utf8.count <= Self.maximumTextBytes else { return nil }
            let before: String?
            switch file["before"] {
            case is NSNull: before = nil
            case let text as String where text.utf8.count <= Self.maximumTextBytes: before = text
            default: return nil
            }
            files.append(File(path: path, before: before, after: after))
        }
        self.files = files
        self.apply = apply.boolValue
    }

    /// No file contents: the bridge logs requests by their description.
    public var description: String { "AgentPaneTurnUndo(files: \(files.count), apply: \(apply))" }

    /// Runs the request against `roots` (the pane's roots), off the main actor: it touches the disk.
    @concurrent static func run(_ undo: AgentPaneTurnUndo, roots: [String],
                                trash: @escaping @Sendable (URL) throws -> Void) async -> [(path: String, status: Status)] {
        let canonicalRoots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        return undo.files.map { file in (file.path, Self.run(file, apply: undo.apply, roots: canonicalRoots, trash: trash)) }
    }

    /// One file. Every step after the folder check works relative to one descriptor of the
    /// folder (opened without following a final symlink, its real path checked against the roots),
    /// so a folder swapped for a symlink after the check cannot redirect the read, write or rename.
    static func run(_ file: File, apply: Bool, roots: [String], trash: (URL) throws -> Void) -> Status {
        let url = URL(fileURLWithPath: file.path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              let canonicalFolder = AcpmuxPathPolicy.canonical(url.deletingLastPathComponent().path) else { return .cannotUndo }
        let folder = open(canonicalFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return .cannotUndo }
        defer { close(folder) }
        // Where the descriptor really is now, not where the string pointed a moment ago.
        guard let held = Self.path(of: folder) else { return .cannotUndo }
        let real = AcpmuxPathPolicy.canonical(held) ?? held
        let path = (real as NSString).appendingPathComponent(name)
        guard roots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: path) }) else { return .outsideRoots }
        let after = Data(file.after.utf8)
        let found = Self.check(folder, name, holds: after)
        guard case .regular(let mode) = found else { return found.status }
        guard apply else { return file.before == nil ? .wouldTrash : .wouldRevert }
        guard let before = file.before else {
            // Checked again right before the move: the Trash call takes a path.
            guard case .regular = Self.check(folder, name, holds: after) else { return .changed }
            do {
                try trash(URL(fileURLWithPath: path))
                return .trashed
            } catch {
                return .cannotUndo
            }
        }
        return Self.replace(name, in: folder, with: Data(before.utf8), expecting: after, mode: mode)
    }

    /// What a file is, read relative to its folder's descriptor.
    enum Check {
        /// A regular file with one name that holds exactly the expected bytes, and its permission bits.
        case regular(mode_t)
        case failed(Status)

        var status: Status {
            switch self {
            case .regular: .cannotUndo
            case .failed(let status): status
            }
        }
    }

    static func check(_ folder: Int32, _ name: String, holds expected: Data) -> Check {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .failed(.cannotUndo) }
        // A second name keeps the turn's content after the rename: refuse it.
        guard info.st_nlink == 1 else { return .failed(.cannotUndo) }
        // Over the cap is "cannot undo", never "changed": the user did not change it.
        guard info.st_size <= off_t(maximumTextBytes) else { return .failed(.cannotUndo) }
        guard let bytes = Self.contents(folder, name) else { return .failed(.cannotUndo) }
        return bytes == expected ? .regular(info.st_mode & 0o7777) : .failed(.changed)
    }

    /// The real path of a descriptor (F_GETPATH).
    static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The file's bytes, opened relative to `folder` without following a symlink; nil when it
    /// cannot be read or is over ``maximumTextBytes``.
    static func contents(_ folder: Int32, _ name: String) -> Data? {
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        // A regular file: each read returns data or EOF, so the bounded loop ends by the cap.
        for _ in 0...(maximumTextBytes / buffer.count + 1) {
            // concurrency-allow: only AgentPaneTurnUndo.run (@concurrent) calls this, never the main actor.
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > maximumTextBytes { return nil }
        }
        return nil
    }

    /// Writes `bytes` to a temporary file in `folder` with the original's permission bits,
    /// extended attributes and ACL, checks the file still holds `expecting`, then renames the
    /// temporary file over it. Any failure removes the temporary file and leaves the original.
    static func replace(_ name: String, in folder: Int32, with bytes: Data, expecting: Data, mode: mode_t) -> Status {
        let temporary = ".cmux-undo-\(UUID().uuidString)"
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { return .cannotUndo }
        let written = bytes.withUnsafeBytes { raw -> Bool in
            // An empty text has no buffer and nothing to write.
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                // concurrency-allow: only AgentPaneTurnUndo.run (@concurrent) calls this, never the main actor.
                let count = write(descriptor, base + offset, raw.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        // open's mode is masked by the umask; the file keeps the original's bits.
        let kept = fchmod(descriptor, mode) == 0 && Self.copyMetadata(from: name, in: folder, to: descriptor)
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written, kept, synced else {
            unlinkat(folder, temporary, 0)
            return .cannotUndo
        }
        let now = Self.check(folder, name, holds: expecting)
        guard case .regular = now else {
            unlinkat(folder, temporary, 0)
            return now.status
        }
        guard renameat(folder, temporary, folder, name) == 0 else {
            unlinkat(folder, temporary, 0)
            return .cannotUndo
        }
        return .reverted
    }

    /// The original's extended attributes and ACL onto the temporary file.
    static func copyMetadata(from name: String, in folder: Int32, to destination: Int32) -> Bool {
        let source = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { return false }
        defer { close(source) }
        return fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0
    }
}

extension AgentPaneModel {
    /// `turn.undo` arrived without a real click or key press in the pane.
    static var turnUndoNeedsGestureMessage: String {
        String(localized: "agentPane.error.turnUndoGesture", defaultValue: "Undo needs a click or key press in the pane.", bundle: .module)
    }

    /// `turn.undo` whose params break its contract.
    static var turnUndoInvalidMessage: String {
        String(localized: "agentPane.error.turnUndoInvalid", defaultValue: "The app refused the undo request.", bundle: .module)
    }

    /// `turn.undo`: spends the GRANT credit, then runs the request against the pane's roots.
    func respondToTurnUndo(_ undo: AgentPaneTurnUndo) async -> [String: Any] {
        guard transport.gestures.consume() else {
            return AgentPaneReply.failure(code: AgentPaneTransportError.gestureRequired.rawValue,
                                          message: Self.turnUndoNeedsGestureMessage, details: nil, retryable: nil, origin: "native")
        }
        let results = await AgentPaneTurnUndo.run(undo, roots: roots() + transport.addedRoots, trash: trashFile)
        return AgentPaneReply.success(["files": results.map { ["path": $0.path, "status": $0.status.rawValue] }])
    }
}
