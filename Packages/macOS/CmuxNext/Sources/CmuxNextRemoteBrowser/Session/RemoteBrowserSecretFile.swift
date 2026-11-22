public import Foundation

#if DEBUG
/// A remote browser host's per-launch secret, kept in a file that only this
/// user can read (like an SSH key): the address form's secure source
/// (cx-erey). The host gets its secret as the first line of its stdin
/// (`--lifeline`), so a person who starts one by hand writes the same value
/// to a private file and names the file. The tab record keeps the path,
/// never the secret; the secret is read when the tab connects and goes only
/// into the rd hello.
public nonisolated struct RemoteBrowserSecretFile: Sendable, Hashable {
    /// Why a secret file was not used.
    public enum Failure: Error, Equatable, Sendable {
        case missing
        /// A directory, socket or other non-file.
        case notRegularFile
        /// Another user owns the file.
        case notOwned
        /// The group or other users have any permission on it.
        case notPrivate
        /// No secret on the first line.
        case empty
        case unreadable
    }

    /// The absolute path (`~` expanded).
    public let path: String

    /// Longest first line read (a host secret is 64 hex characters).
    static let maxBytes = 4096

    public init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
    }

    /// The trimmed first line. The checks run on the opened descriptor, so
    /// the file that is checked is the file that is read.
    public func read() throws(Failure) -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile }
        guard info.st_uid == getuid() else { throw .notOwned }
        guard info.st_mode & 0o077 == 0 else { throw .notPrivate }
        var bytes = [UInt8](repeating: 0, count: Self.maxBytes)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw .unreadable }
        let text = String(decoding: bytes.prefix(count), as: UTF8.self)
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let secret = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw .empty }
        return secret
    }
}
#endif
