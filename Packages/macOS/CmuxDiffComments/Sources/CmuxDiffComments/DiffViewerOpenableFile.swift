import Foundation

/// The file a diff viewer page may open: `path` must name a regular file
/// inside the git work tree at `repoRoot` and outside any `.git` directory,
/// after symlinks resolve. Returns its canonical URL, or nil.
public func diffViewerOpenableFileURL(repoRoot: String, path: String) -> URL? {
    guard repoRoot.hasPrefix("/"), !path.isEmpty, !path.hasPrefix("/"),
          FileManager.default.fileExists(atPath: (repoRoot as NSString).appendingPathComponent(".git")),
          let root = canonicalPath(repoRoot),
          let file = canonicalPath((root as NSString).appendingPathComponent(path)) else {
        return nil
    }
    let rootComponents = (root as NSString).pathComponents
    let fileComponents = (file as NSString).pathComponents
    guard fileComponents.count > rootComponents.count,
          Array(fileComponents.prefix(rootComponents.count)) == rootComponents,
          !fileComponents.dropFirst(rootComponents.count).contains(where: { $0.lowercased() == ".git" }),
          (try? FileManager.default.attributesOfItem(atPath: file)[.type] as? FileAttributeType) == .typeRegular else {
        return nil
    }
    return URL(fileURLWithPath: file, isDirectory: false)
}

private func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
