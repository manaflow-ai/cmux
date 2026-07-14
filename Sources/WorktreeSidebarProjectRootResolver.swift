import Foundation

/// Resolves linked Git worktrees to the main checkout used to group sidebar sections.
struct WorktreeSidebarProjectRootResolver: Sendable {
    @concurrent
    func projectRoot(onDiskFor directory: String) async -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fileManager = FileManager.default

        while url.path != "/" {
            let dotGit = url.appendingPathComponent(".git", isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
                url.deleteLastPathComponent()
                continue
            }
            guard !isDirectory.boolValue,
                  let gitDirectory = linkedGitDirectory(from: dotGit),
                  let commonDirectory = commonGitDirectory(from: gitDirectory),
                  commonDirectory.lastPathComponent == ".git" else {
                return url.path
            }
            return commonDirectory.deletingLastPathComponent().path
        }
        return nil
    }

    private func linkedGitDirectory(from marker: URL) -> URL? {
        guard let data = try? Data(contentsOf: marker),
              let line = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first.map(String.init),
              line.hasPrefix("gitdir:") else {
            return nil
        }
        let rawPath = line.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        return URL(
            fileURLWithPath: rawPath,
            relativeTo: marker.deletingLastPathComponent()
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
    }

    private func commonGitDirectory(from gitDirectory: URL) -> URL? {
        let marker = gitDirectory.appendingPathComponent("commondir", isDirectory: false)
        guard let data = try? Data(contentsOf: marker),
              let rawPath = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath, relativeTo: gitDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
