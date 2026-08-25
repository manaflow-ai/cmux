import Darwin
import Foundation

/// Reopens a sidebar row with descriptor-level project-root confinement.
struct ArtifactSidebarFileAccess {
    let fileManager: FileManager

    /// Keeps the descriptor that passed artifact-root validation alive while a
    /// preview or diff reader consumes the file. `/dev/fd` refers to this
    /// descriptor, so replacing the original pathname cannot redirect reads.
    final class OpenedFile {
        let sourceURL: URL
        private let descriptor: Int32

        var readURL: URL {
            URL(fileURLWithPath: "/dev/fd/\(descriptor)", isDirectory: false)
        }

        init(sourceURL: URL, descriptor: Int32) {
            self.sourceURL = sourceURL
            self.descriptor = descriptor
        }

        /// Duplicates the descriptor for a trusted child process and clears
        /// close-on-exec so the child can read its `/dev/fd` path.
        func duplicateForChildProcess() -> Int32? {
            let duplicate = fcntl(descriptor, F_DUPFD, 3)
            guard duplicate >= 0 else { return nil }
            let flags = fcntl(duplicate, F_GETFD)
            guard flags >= 0, fcntl(duplicate, F_SETFD, flags & ~FD_CLOEXEC) == 0 else {
                _ = Darwin.close(duplicate)
                return nil
            }
            return duplicate
        }

        deinit {
            _ = Darwin.close(descriptor)
        }
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the current canonical file URL when the row still belongs to
    /// the resolved project artifact root.
    func validatedFileURL(for sourceURL: URL, artifactRoot: URL) -> URL? {
        openedFile(for: sourceURL, artifactRoot: artifactRoot)?.sourceURL
    }

    /// Opens and validates one artifact while retaining the validated inode.
    func openedFile(for sourceURL: URL, artifactRoot: URL) -> OpenedFile? {
        guard sourceURL.isFileURL else { return nil }
        let descriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              let openedPath = openedPath(for: descriptor) else {
            _ = Darwin.close(descriptor)
            return nil
        }
        let rootPath = artifactRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = openedPath.path
        guard path == rootPath
                || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return OpenedFile(sourceURL: openedPath, descriptor: descriptor)
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
