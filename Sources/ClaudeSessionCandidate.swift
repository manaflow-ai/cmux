import Foundation

/// One Claude transcript `.jsonl` file discovered under a session root, paired
/// with the metadata needed to rank, filter, and resume it.
struct ClaudeSessionCandidate: Sendable {
    let url: URL
    let mtime: Date
    let dirName: String
    let resumeConfigDirectory: String?
    let prefilteredByRipgrep: Bool

    /// The encoded project directory name owning `url`, derived from its path
    /// relative to `projectsRoot`. Falls back to the URL's parent directory name
    /// when the URL is not under the projects root.
    static func projectDirName(for url: URL, projectsRoot: String) -> String {
        let root = projectsRoot.hasSuffix("/") ? projectsRoot : projectsRoot + "/"
        guard url.path.hasPrefix(root) else {
            return url.deletingLastPathComponent().lastPathComponent
        }
        let relative = String(url.path.dropFirst(root.count))
        return relative.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? url.deletingLastPathComponent().lastPathComponent
    }

    /// Enumerate `.jsonl` transcript candidates under `root`. When `cwdFilter` is
    /// set, only the single encoded-cwd project directory is scanned (fast path);
    /// otherwise every project directory under the root is scanned.
    static func enumerate(
        root: ClaudeSessionRoot,
        cwdFilter: String?,
        prefilteredByRipgrep: Bool
    ) -> [ClaudeSessionCandidate] {
        let fm = FileManager.default
        var candidates: [ClaudeSessionCandidate] = []

        func appendJSONLFiles(in dirPath: String, dirName: String) {
            guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
            for name in contents where name.hasSuffix(".jsonl") {
                let filePath = (dirPath as NSString).appendingPathComponent(name)
                let url = URL(fileURLWithPath: filePath)
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                candidates.append(
                    ClaudeSessionCandidate(
                        url: url,
                        mtime: mtime,
                        dirName: dirName,
                        resumeConfigDirectory: root.resumeConfigDirectory,
                        prefilteredByRipgrep: prefilteredByRipgrep
                    )
                )
            }
        }

        if let cwdFilter {
            // Single-sourced with RestorableAgentSessionIndex so this fast-path cwd filter
            // encodes dotted paths ("." -> "-") identically to the transcript-discovery path.
            let dirName = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwdFilter)
            let dirPath = (root.projectsRoot as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
                appendJSONLFiles(in: dirPath, dirName: dirName)
            }
            return candidates
        }

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: root.projectsRoot) else {
            return candidates
        }
        for dirName in projectDirs {
            let dirPath = (root.projectsRoot as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            appendJSONLFiles(in: dirPath, dirName: dirName)
        }
        return candidates
    }
}
