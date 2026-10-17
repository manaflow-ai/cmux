import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The owner side of the Files page (`cmux.files.*`, cx-p4rt), for one tab's folder: `root` (the
/// folder), `list {path}` (one folder's children through the session host's `git.files.list`, and,
/// for a folder on this Mac, what else the folder holds marked `ignored`, which the page greys out;
/// Lucas 2026-10-17), `search {query}` (the session host's `git.files.search`, paths relative to the
/// tab's folder) and `open {path}` (a file in the file pages). `path` is relative to the tab's
/// folder; the page never names a file outside it.
@MainActor
final class FileTreePageProvider: PageProvider {
    private let folder: URL?
    private let link: AgentPaneGitLink?
    private let open: @MainActor (URL) -> String?

    init(folder: URL?, link: AgentPaneGitLink?, open: @escaping @MainActor (URL) -> String?) {
        self.folder = folder
        self.link = link
        self.open = open
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard let folder else { throw PageError(code: "cmux.files.no_folder", message: FileTreeStrings.noFolder, retryable: false) }
        switch op {
        case "cmux.files.root":
            return ["folder": .string(folder.path), "name": .string(folder.lastPathComponent)]
        case "cmux.files.list":
            return try await list(Self.resolve(params["path"]?.stringValue, in: folder))
        case "cmux.files.search":
            return try await search(params["query"]?.stringValue ?? "", in: folder)
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
            let listed = reply["entries"]?.arrayValue ?? []
            let ignored = link.isLocal ? Self.ignored(in: directory, besides: listed) : []
            return ["entries": .array(Self.sorted(listed + ignored)),
                    "truncated": .bool(reply["truncated"]?.boolValue == true || ignored.count >= Self.ignoredLimit)]
        } catch let failure as AgentPaneGitFailure {
            throw PageError(code: "cmux.files.unavailable", message: FileTreeStrings.message(for: failure), retryable: true)
        }
    }

    /// Files search: the session host's ranked matches under `folder`, as paths relative to it.
    private func search(_ query: String, in folder: URL) async throws -> CmuxNextSettings.JSONValue {
        guard let link else { throw PageError(code: "cmux.files.unavailable", message: FileTreeStrings.unavailable, retryable: true) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256, !trimmed.contains("\u{0}") else { return ["results": .array([])] }
        do {
            let reply = try await CmuxNextSettings.JSONValue.parse(link.read("git.files.search", params: [
                "path": .string(folder.path), "query": .string(trimmed), "limit": .number(100),
            ]))
            let root = URL(fileURLWithPath: reply["root"]?.stringValue ?? folder.path, isDirectory: true).standardizedFileURL.path
            let base = folder.standardizedFileURL.path
            let results: [CmuxNextSettings.JSONValue] = (reply["results"]?.arrayValue ?? []).compactMap { result in
                guard let path = result["path"]?.stringValue else { return nil }
                let absolute = (root as NSString).appendingPathComponent(path)
                guard absolute.hasPrefix(base + "/") else { return nil }
                return ["path": .string(String(absolute.dropFirst(base.count + 1)))]
            }
            return ["results": .array(results)]
        } catch let failure as AgentPaneGitFailure {
            throw PageError(code: "cmux.files.unavailable", message: FileTreeStrings.message(for: failure), retryable: true)
        }
    }

    /// Ignored entries one listing adds at most; a bigger folder (node_modules) says it was cut short.
    nonisolated static let ignoredLimit = 500

    /// What `directory` holds that git's listing left out (ignored files and folders), as entries
    /// marked `ignored`; never `.git`.
    nonisolated static func ignored(in directory: URL, besides listed: [CmuxNextSettings.JSONValue]) -> [CmuxNextSettings.JSONValue] {
        let known = Set(listed.compactMap { $0["name"]?.stringValue })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [CmuxNextSettings.JSONValue] = []
        for name in names.sorted() where !known.contains(name) && name != ".git" && name != ".DS_Store" {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory) else { continue }
            entries.append(["name": .string(name), "kind": .string(isDirectory.boolValue ? "directory" : "file"), "ignored": .bool(true)])
            if entries.count >= ignoredLimit { break }
        }
        return entries
    }

    /// Folders first, then files, each by name as Finder sorts them.
    nonisolated static func sorted(_ entries: [CmuxNextSettings.JSONValue]) -> [CmuxNextSettings.JSONValue] {
        entries.sorted { a, b in
            let folderA = a["kind"]?.stringValue == "directory", folderB = b["kind"]?.stringValue == "directory"
            if folderA != folderB { return folderA }
            return (a["name"]?.stringValue ?? "").localizedStandardCompare(b["name"]?.stringValue ?? "") == .orderedAscending
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
