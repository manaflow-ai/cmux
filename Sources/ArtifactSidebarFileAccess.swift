import Darwin
import Foundation

/// Reopens a sidebar row with descriptor-level project-root confinement.
struct ArtifactSidebarFileAccess {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the current canonical file URL when the row still belongs to
    /// the resolved project artifact root.
    func validatedFileURL(for sourceURL: URL, artifactRoot: URL) -> URL? {
        guard sourceURL.isFileURL,
              fileManager.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        let descriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              let openedPath = openedPath(for: descriptor) else {
            return nil
        }
        let rootPath = artifactRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = openedPath.path
        guard path == rootPath
                || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            return nil
        }
        return openedPath
    }

    private func openedPath(for descriptor: Int32) -> URL? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { bytes in
            fcntl(descriptor, F_GETPATH, bytes.baseAddress)
        }
        guard result == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }
}
