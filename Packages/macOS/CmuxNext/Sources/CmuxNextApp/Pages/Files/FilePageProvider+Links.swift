import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Link targets and the `[[` completion list of a file page: relative to the tab's own file,
/// symlinks resolved before every folder check.
extension FilePageProvider {
    /// The real path of a relative link target of the tab's file, inside its folder or a workspace root.
    func target(_ relative: String, from base: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\u{0}") else { return nil }
        let real = base.deletingLastPathComponent().appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
        let folder = base.deletingLastPathComponent().path
        guard real.path.hasPrefix(folder + "/") || host?.roots.contains(real.path) == true else { return nil }
        return real
    }

    func linkBase(_ params: JSONValue) throws -> URL {
        let from = try path(params["from"])
        guard let file, from.resolvingSymlinksInPath() == file else { throw PageError.invalidParams("from is not this page's file") }
        return file
    }

    func listFiles(_ params: JSONValue) throws -> JSONValue {
        let base = try linkBase(params)
        let prefix = params["prefix"]?.stringValue ?? ""
        guard !prefix.hasPrefix("/"), !prefix.split(separator: "/").contains("..") else { return ["entries": []] }
        let folderPart = prefix.lastIndex(of: "/").map { String(prefix[...$0]) } ?? ""
        let start = String(prefix.dropFirst(folderPart.count)).lowercased()
        // Symlinks resolved before the folder check: a link in the folder may point anywhere.
        let root = Self.canonical(base.deletingLastPathComponent())
        let directory = folderPart.isEmpty ? root : Self.canonical(root.appending(path: folderPart, directoryHint: .isDirectory))
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return ["entries": []] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let entries = names
            .filter { !$0.hasPrefix(".") && $0 != "node_modules" && $0.lowercased().hasPrefix(start) }
            .map { name -> (String, Bool) in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: directory.appending(path: name).path, isDirectory: &isDirectory)
                return (name, isDirectory.boolValue)
            }
            .sorted { $0.1 != $1.1 ? $0.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .prefix(Self.listLimit)
            .map { JSONValue.string(folderPart + $0.0 + ($0.1 ? "/" : "")) }
        return ["entries": .array(Array(entries))]
    }
}
