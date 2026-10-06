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
/// symlink; its bytes equal `after` exactly, read again right before the write; the write is a
/// temporary file in the same folder, renamed over the file with its permissions kept; a file the
/// turn created goes to the Trash. A file that fails a rule keeps its bytes.
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

    static func run(_ file: File, apply: Bool, roots: [String], trash: (URL) throws -> Void) -> Status {
        let url = URL(fileURLWithPath: file.path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              let folder = AcpmuxPathPolicy.canonical(url.deletingLastPathComponent().path) else { return .cannotUndo }
        let path = (folder as NSString).appendingPathComponent(name)
        guard roots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: path) }) else { return .outsideRoots }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .cannotUndo }
        let after = Data(file.after.utf8)
        switch Self.contents(path) {
        case nil: return .cannotUndo
        case let bytes? where bytes != after: return .changed
        default: break
        }
        guard apply else { return file.before == nil ? .wouldTrash : .wouldRevert }
        guard let before = file.before else {
            do {
                try trash(URL(fileURLWithPath: path))
                return .trashed
            } catch {
                return .cannotUndo
            }
        }
        return Self.replace(path, folder: folder, with: Data(before.utf8), expecting: after, mode: info.st_mode & 0o7777)
    }

    /// The file's bytes, read without following a symlink; nil when it cannot be read.
    static func contents(_ path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > maximumTextBytes { return data }
        }
    }

    /// Writes `bytes` to a temporary file next to `path`, checks `path` still holds `expecting`,
    /// then renames the temporary file over it.
    static func replace(_ path: String, folder: String, with bytes: Data, expecting: Data, mode: mode_t) -> Status {
        let temporary = (folder as NSString).appendingPathComponent(".cmux-undo-\(UUID().uuidString)")
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { return .cannotUndo }
        let written = bytes.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        // open's mode is masked by the umask; the file keeps the original's bits.
        let kept = fchmod(descriptor, mode) == 0
        let synced = fsync(descriptor) == 0
        close(descriptor)
        var info = stat()
        guard written, kept, synced, lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              Self.contents(path) == expecting, rename(temporary, path) == 0 else {
            unlink(temporary)
            return Self.contents(path) == expecting ? .cannotUndo : .changed
        }
        return .reverted
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
