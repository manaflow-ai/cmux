package import CmuxNextPages
package import CmuxNextSettings
package import Foundation

/// Search and local ignored entries for the chat's Files page.
@MainActor
package struct AgentFileTreeReads: Sendable {
    package nonisolated init() {}

    /// Merges a complete local git listing with ignored disk entries off the main actor.
    package func listing(_ reply: JSONValue, directory: URL, local: Bool) async -> JSONValue {
        let listed = reply["entries"]?.arrayValue ?? []
        let cut = reply["truncated"]?.boolValue == true
        // A listing git cut short leaves tracked names out, which the disk scan would call ignored.
        let ignored = local && !cut
            ? await Task.detached(priority: .userInitiated) { self.ignored(in: directory, besides: listed) }.value : []
        return ["entries": .array(sorted(listed + ignored)), "truncated": .bool(cut || ignored.count >= ignoredLimit)]
    }

    /// Files search: the session host's ranked matches under the requested folder, as paths relative to it.
    package func search(_ query: String, read: @MainActor (String) async throws -> Data, failure: @MainActor (AgentPaneGitFailure) -> PageError) async throws -> CmuxNextSettings.JSONValue {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256, !trimmed.contains("\u{0}") else { return ["results": .array([])] }
        do {
            let reply = try await CmuxNextSettings.JSONValue.parse(read(trimmed))
            return ["results": .array(searchResults(reply["results"]?.arrayValue ?? []).map { ["path": .string($0)] })]
        } catch let error as AgentPaneGitFailure {
            throw failure(error)
        }
    }

    /// The search's result paths the page may name: the session host gives them relative to the
    /// folder searched (the tab's), so they are kept as they are; one that is absolute or steps out
    /// (`..`, `.`, empty parts, NUL) is dropped. The provider resolves each path again when opening it.
    package nonisolated func searchResults(_ results: [CmuxNextSettings.JSONValue]) -> [String] {
        results.compactMap { result in
            guard let path = result["path"]?.stringValue, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\u{0}"),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else { return nil }
            return path
        }
    }

    /// Ignored entries one listing adds at most; a bigger folder (node_modules) says it was cut short.
    private nonisolated var ignoredLimit: Int { 500 }

    /// What `directory` holds that git's listing left out (ignored files and folders), as entries
    /// marked `ignored`; never `.git`.
    private nonisolated func ignored(in directory: URL, besides listed: [CmuxNextSettings.JSONValue]) -> [CmuxNextSettings.JSONValue] {
        let known = Set(listed.compactMap { $0["name"]?.stringValue })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [CmuxNextSettings.JSONValue] = []
        for name in names.sorted() where !known.contains(name) && name != ".git" && name != ".DS_Store" {
            // The entry itself, not what a symlink points at: a link to a folder elsewhere is a file
            // here, never a folder the tree would open outside the tab's folder.
            guard let type = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.type]
                    as? FileAttributeType else { continue }
            let folder = type == .typeDirectory
            // An empty folder is no ignored one: git never lists empty folders.
            if folder, (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(name).path))?.isEmpty == true { continue }
            entries.append(["name": .string(name), "kind": .string(folder ? "directory" : "file"), "ignored": .bool(true)])
            if entries.count >= ignoredLimit { break }
        }
        return entries
    }

    /// Folders first, then files, each by name as Finder sorts them.
    private nonisolated func sorted(_ entries: [CmuxNextSettings.JSONValue]) -> [CmuxNextSettings.JSONValue] {
        entries.sorted { a, b in
            let folderA = a["kind"]?.stringValue == "directory", folderB = b["kind"]?.stringValue == "directory"
            if folderA != folderB { return folderA }
            return (a["name"]?.stringValue ?? "").localizedStandardCompare(b["name"]?.stringValue ?? "") == .orderedAscending
        }
    }
}
