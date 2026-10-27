import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The owner side of the Files page (`cmux.files.*`, cx-p4rt), for one tab's folder: `root` (the
/// folder), `list {path}` (one folder's children through the session host's `git.files.list`, so
/// ignored files never show) and `open {path}` (a file in the file pages). `path` is relative to the
/// tab's folder; the page never names a file outside it.
@MainActor
final class FileTreePageProvider: PageProvider {
    private let folder: URL?
    private let link: AgentPaneGitLink?
    private let open: @MainActor (URL) -> String?
    /// What the tab's previous page showed before it was discarded (its `cmux.files.viewState`
    /// answer): the next `root` answer carries it once as `viewState`.
    var viewState: CmuxNextSettings.JSONValue?

    init(folder: URL?, link: AgentPaneGitLink?, open: @escaping @MainActor (URL) -> String?) {
        self.folder = folder
        self.link = link
        self.open = open
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard let folder else { throw PageError(code: "cmux.files.no_folder", message: FileTreeStrings.noFolder, retryable: false) }
        switch op {
        case "cmux.files.root":
            var root: [String: CmuxNextSettings.JSONValue] = ["folder": .string(folder.path), "name": .string(folder.lastPathComponent)]
            if let viewState {
                self.viewState = nil
                root["viewState"] = viewState
            }
            return .object(root)
        case "cmux.files.list":
            return try await list(Self.resolve(params["path"]?.stringValue, in: folder))
        case "cmux.files.open":
            let file = try Self.resolve(params["path"]?.stringValue, in: folder)
            if let failure = open(file) { throw PageError(code: "cmux.files.open_failed", message: failure, retryable: false) }
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    private func list(_ directory: URL) async throws -> CmuxNextSettings.JSONValue {
        guard let link else { throw PageError(code: "cmux.files.unavailable", message: FileTreeStrings.unavailable, retryable: true) }
        do {
            let reply = try await CmuxNextSettings.JSONValue.parse(link.read("git.files.list", params: ["path": .string(directory.path)]))
            return ["entries": reply["entries"] ?? .array([]), "truncated": reply["truncated"] ?? .bool(false)]
        } catch let failure as AgentPaneGitFailure {
            throw PageError(code: "cmux.files.unavailable", message: FileTreeStrings.message(for: failure), retryable: true)
        }
    }

    /// `path` ('/'-separated, "" for the folder itself) inside `folder`; anything that could leave it
    /// (absolute, `..`, `.`, empty components, NUL, or a symlink pointing outside) is refused.
    nonisolated static func resolve(_ path: String?, in folder: URL) throws -> URL {
        guard let path else { throw PageError.invalidParams("path is required") }
        guard !path.isEmpty else { return folder }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\u{0}"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PageError.invalidParams("path must be relative to the folder")
        }
        let target = parts.reduce(folder) { $0.appendingPathComponent(String($1)) }
        let root = realPath(folder)
        let real = realPath(target)
        guard real == root || real.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw PageError.invalidParams("path must be relative to the folder")
        }
        return target
    }

    /// `url` with its symlinks resolved. Foundation drops `/private` (macOS's `/tmp`, `/var`) only for
    /// a path that exists, so a missing tail (a file just deleted) joins its nearest existing folder.
    private nonisolated static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil, existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
}
