import Darwin
import Foundation


// MARK: - Diff Viewer Directory and Bundled Assets
extension CMUXCLI {
    func diffViewerDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(getuid())", isDirectory: true)
        try ensureSecureDiffViewerDirectory(directory)
        pruneDiffViewerFiles(in: directory)
        return directory
    }

    private func ensureSecureDiffViewerDirectory(_ directory: URL) throws {
        let path = directory.path
        if mkdir(path, mode_t(0o700)) != 0 {
            let mkdirErrno = errno
            guard mkdirErrno == EEXIST else {
                throw CLIError(message: "Failed to create diff viewer directory: \(posixErrorMessage(mkdirErrno))")
            }
        }

        try validateSecureDiffViewerDirectory(directory, repairPermissions: true)
    }

    func validateSecureDiffViewerDirectory(_ directory: URL, repairPermissions: Bool) throws {
        let path = directory.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw CLIError(message: "Failed to inspect diff viewer directory: \(posixErrorMessage(errno))")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw CLIError(message: "Unsafe diff viewer directory is not a directory: \(path)")
        }
        guard info.st_uid == getuid() else {
            throw CLIError(message: "Unsafe diff viewer directory is not owned by the current user: \(path)")
        }

        let permissionBits = info.st_mode & mode_t(0o777)
        guard permissionBits == mode_t(0o700) else {
            guard repairPermissions else {
                throw CLIError(message: "Unsafe diff viewer directory permissions: \(path)")
            }
            if chmod(path, mode_t(0o700)) != 0 {
                throw CLIError(message: "Failed to secure diff viewer directory: \(posixErrorMessage(errno))")
            }
            try validateSecureDiffViewerDirectory(directory, repairPermissions: false)
            return
        }
    }

    func ensureDiffViewerAssets(nextTo viewerURL: URL, runtime: URL? = nil) throws -> DiffViewerAssets {
        let sourceDirectory = try diffViewerBundledAssetDirectory(runtime: runtime)
        let assetDirectoryName = "pierre-diffs-1.2.7-trees-1.0.0-beta.4"
        let targetDirectory = viewerURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(assetDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let appAssets = try diffViewerBundledAppAssetDirectory(nextTo: sourceDirectory)
        let appAssetDirectoryName = appAssets.targetDirectoryName
        let targetAppDirectory = viewerURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(appAssetDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetAppDirectory, withIntermediateDirectories: true)

        let assetPaths = try diffViewerBundledAssetRelativePaths(in: sourceDirectory)
        guard assetPaths.contains("diffs.mjs"),
              assetPaths.contains("trees.mjs"),
              assetPaths.contains("worker-pool/worker-pool.mjs"),
              assetPaths.contains("worker-pool/worker-portable.js") else {
            throw CLIError(message: "Bundled diff viewer entry assets not found")
        }
        for assetPath in assetPaths {
            try copyDiffViewerAsset(relativePath: assetPath, from: sourceDirectory, to: targetDirectory)
        }

        let appAssetPaths = try diffViewerBundledAssetRelativePaths(in: appAssets.sourceDirectory)
        guard appAssetPaths.contains("main.mjs") else {
            throw CLIError(message: "Bundled cmux diff viewer app entry asset not found")
        }
        for assetPath in appAssetPaths {
            try copyDiffViewerAsset(relativePath: assetPath, from: appAssets.sourceDirectory, to: targetAppDirectory)
        }

        return DiffViewerAssets(
            appModuleURL: "./assets/\(appAssetDirectoryName)/main.mjs",
            diffsModuleURL: "./assets/\(assetDirectoryName)/diffs.mjs",
            treesModuleURL: "./assets/\(assetDirectoryName)/trees.mjs",
            workerPoolModuleURL: "./assets/\(assetDirectoryName)/worker-pool/worker-pool.mjs",
            workerModuleURL: "./assets/\(assetDirectoryName)/worker-pool/worker-portable.js",
            files: assetPaths.map { targetDirectory.appendingPathComponent($0, isDirectory: false) }
                + appAssetPaths.map { targetAppDirectory.appendingPathComponent($0, isDirectory: false) }
        )
    }

    private func diffViewerBundledAppAssetDirectory(
        nextTo sourceDirectory: URL
    ) throws -> (sourceDirectory: URL, targetDirectoryName: String) {
        let sourceRoot = sourceDirectory.deletingLastPathComponent()
        let candidates: [(sourceName: String, targetName: String)] = [
            ("webviews-app", "cmux-webviews-app"),
            ("diff-viewer-app", "cmux-diff-viewer-app")
        ]
        for candidate in candidates {
            let appDirectory = sourceRoot
                .appendingPathComponent(candidate.sourceName, isDirectory: true)
                .standardizedFileURL
            let entry = appDirectory.appendingPathComponent("main.mjs", isDirectory: false)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: appDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               FileManager.default.fileExists(atPath: entry.path) {
                return (sourceDirectory: appDirectory, targetDirectoryName: candidate.targetName)
            }
        }
        throw CLIError(message: "Bundled cmux diff viewer app assets not found")
    }

    private func copyDiffViewerAsset(relativePath: String, from sourceDirectory: URL, to targetDirectory: URL) throws {
        let fileManager = FileManager.default
        let sourceURL = sourceDirectory.appendingPathComponent(relativePath, isDirectory: false)
        let targetURL = targetDirectory.appendingPathComponent(relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CLIError(message: "Bundled diff viewer asset not found: \(relativePath)")
        }

        let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if isCurrentDiffViewerAsset(targetURL: targetURL, sourceValues: sourceValues) {
            return
        }

        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = targetURL.deletingLastPathComponent().appendingPathComponent(
            ".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            if rename(temporaryURL.path, targetURL.path) != 0 {
                let code = Int(errno)
                throw NSError(domain: NSPOSIXErrorDomain, code: code)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            if isCurrentDiffViewerAsset(targetURL: targetURL, sourceValues: sourceValues) {
                return
            }
            throw error
        }
    }

    private func diffViewerBundledAssetRelativePaths(in sourceDirectory: URL) throws -> [String] {
        let rootURL = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CLIError(message: "Failed to enumerate diff viewer assets")
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard ["js", "mjs"].contains(fileURL.pathExtension),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let standardized = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard standardized.path.hasPrefix(rootURL.path + "/") else {
                continue
            }
            relativePaths.append(String(standardized.path.dropFirst(rootURL.path.count + 1)))
        }
        return relativePaths.sorted()
    }

    private func isCurrentDiffViewerAsset(targetURL: URL, sourceValues: URLResourceValues) -> Bool {
        guard FileManager.default.fileExists(atPath: targetURL.path),
              let targetValues = try? targetURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              targetValues.fileSize == sourceValues.fileSize,
              let sourceDate = sourceValues.contentModificationDate,
              let targetDate = targetValues.contentModificationDate else {
            return false
        }
        return targetDate >= sourceDate
    }

    private func diffViewerBundledAssetDirectory(runtime: URL? = nil) throws -> URL {
        let candidates = diffViewerBundledAssetDirectoryCandidates(runtime: runtime)
        if let directory = candidates.first {
            return directory
        }
        throw CLIError(message: "Bundled diff viewer assets not found")
    }

    private func diffViewerBundledAssetDirectoryCandidates(runtime: URL? = nil) -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        var seen: Set<String> = []

        func appendIfExisting(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let diffsAsset = standardized.appendingPathComponent("diffs.mjs", isDirectory: false)
            let treesAsset = standardized.appendingPathComponent("trees.mjs", isDirectory: false)
            guard fileManager.fileExists(atPath: diffsAsset.path),
                  fileManager.fileExists(atPath: treesAsset.path) else {
                return
            }
            candidates.append(standardized)
        }

        if let executableURL = diffViewerExecutableURL(for: runtime) {
            let execDir = executableURL.deletingLastPathComponent().standardizedFileURL
            for relativePath in [
                "markdown-viewer/diff-viewer",
                "../markdown-viewer/diff-viewer",
                "../../Resources/markdown-viewer/diff-viewer",
                "../../../Contents/Resources/markdown-viewer/diff-viewer"
            ] {
                appendIfExisting(execDir.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL)
            }

            var current = execDir
            for _ in 0..<6 {
                if current.pathExtension == "app" {
                    appendIfExisting(
                        current
                            .appendingPathComponent("Contents", isDirectory: true)
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("markdown-viewer", isDirectory: true)
                            .appendingPathComponent("diff-viewer", isDirectory: true)
                    )
                    break
                }
                let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj", isDirectory: false)
                let repoAssetDirectory = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("markdown-viewer", isDirectory: true)
                    .appendingPathComponent("diff-viewer", isDirectory: true)
                if fileManager.fileExists(atPath: projectMarker.path) {
                    appendIfExisting(repoAssetDirectory)
                    break
                }
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }

        appendIfExisting(
            Bundle.main.resourceURL?
                .appendingPathComponent("markdown-viewer", isDirectory: true)
                .appendingPathComponent("diff-viewer", isDirectory: true)
        )

        let devRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
        appendIfExisting(devRelative)
        return candidates
    }

    private func pruneDiffViewerFiles(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: []
        ) else {
            return
        }

        let now = Date()
        let sorted = entries.compactMap { url -> (url: URL, date: Date)? in
            guard url.pathExtension == "html",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in sorted.enumerated() where index >= 50 && now.timeIntervalSince(entry.date) > 24 * 60 * 60 {
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: diffViewerPatchFileURL(for: entry.url))
        }

        for patchURL in entries where patchURL.pathExtension == "patch" {
            let htmlURL = patchURL.deletingPathExtension().appendingPathExtension("html")
            guard !FileManager.default.fileExists(atPath: htmlURL.path),
                  let values = try? patchURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? values.creationDate ?? .distantPast) > 24 * 60 * 60 else {
                continue
            }
            try? FileManager.default.removeItem(at: patchURL)
        }

        for manifestURL in entries where manifestURL.lastPathComponent.hasPrefix(".manifest-") && manifestURL.pathExtension == "json" {
            guard let values = try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? values.creationDate ?? .distantPast) > 24 * 60 * 60 else {
                continue
            }
            try? FileManager.default.removeItem(at: manifestURL)
        }
    }

}
