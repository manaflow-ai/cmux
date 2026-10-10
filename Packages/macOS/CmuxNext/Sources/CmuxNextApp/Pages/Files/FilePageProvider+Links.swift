import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Link targets and the `[[` completion list of a file page: relative to the tab's own file,
/// symlinks resolved before every folder check. The file system work (symlink resolution, the
/// folder listing, the existence checks) runs off the main actor; the page state it feeds
/// (`linked`, the granted folders) stays on it.
extension FilePageProvider {
    /// The real path of a relative link target of the tab's file, inside its folder or a workspace root.
    nonisolated static func target(_ relative: String, from base: URL, roots: FileWorkspaceRoots?) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\u{0}") else { return nil }
        let real = base.deletingLastPathComponent().appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
        let folder = base.deletingLastPathComponent().path
        guard real.path.hasPrefix(folder + "/") || roots?.contains(real.path) == true else { return nil }
        return real
    }

    /// `from` (links resolved) must be the tab's file.
    nonisolated static func linkBase(from: URL, file: URL?) throws -> URL {
        guard let file, from.resolvingSymlinksInPath() == file else { throw PageError.invalidParams("from is not this page's file") }
        return file
    }

    func listFiles(_ params: JSONValue) async throws -> JSONValue {
        let from = try path(params["from"])
        let prefix = params["prefix"]?.stringValue ?? ""
        let entries = try await Self.listEntries(from: from, file: file, prefix: prefix)
        return ["entries": .array(entries.map(JSONValue.string))]
    }

    /// The `[[` completion entries under `prefix`: folders first, then names in Finder order, at
    /// most `listLimit`.
    @concurrent nonisolated static func listEntries(from: URL, file: URL?, prefix: String) async throws -> [String] {
        let base = try linkBase(from: from, file: file)
        guard !prefix.hasPrefix("/"), !prefix.split(separator: "/").contains("..") else { return [] }
        let folderPart = prefix.lastIndex(of: "/").map { String(prefix[...$0]) } ?? ""
        let start = String(prefix.dropFirst(folderPart.count)).lowercased()
        // Symlinks resolved before the folder check: a link in the folder may point anywhere.
        let root = canonical(base.deletingLastPathComponent())
        let directory = folderPart.isEmpty ? root : canonical(root.appending(path: folderPart, directoryHint: .isDirectory))
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && $0 != "node_modules" && $0.lowercased().hasPrefix(start) }
            .map { name -> (String, Bool) in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: directory.appending(path: name).path, isDirectory: &isDirectory)
                return (name, isDirectory.boolValue)
            }
            .sorted { $0.1 != $1.1 ? $0.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .prefix(listLimit)
            .map { folderPart + $0.0 + ($0.1 ? "/" : "") }
    }

    /// What `resolveLinks` found for each relative path, and the real paths of the Markdown files
    /// among them (the caller grants those inside a granted folder).
    @concurrent nonisolated static func resolve(_ relatives: [String], from: URL, file: URL?,
                                                roots: FileWorkspaceRoots?) async throws -> (links: [String: JSONValue], markdown: [String]) {
        let base = try linkBase(from: from, file: file)
        var links: [String: JSONValue] = [:]
        var markdown: [String] = []
        for relative in relatives {
            guard let real = target(relative, from: base, roots: roots) else {
                links[relative] = ["exists": false]
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory) else {
                links[relative] = ["exists": false, "path": .string(real.path)]
                continue
            }
            let kind = isDirectory.boolValue ? "directory" : FilePageKind.isMarkdown(real) ? "markdown" : "file"
            if kind == "markdown" { markdown.append(real.path) }
            links[relative] = ["exists": true, "path": .string(real.path), "kind": .string(kind)]
        }
        return (links, markdown)
    }
}
