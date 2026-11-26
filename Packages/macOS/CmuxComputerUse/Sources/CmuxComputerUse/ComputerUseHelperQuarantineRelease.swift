import Darwin
import Foundation

/// Removes macOS file quarantine from a copied helper bundle tree.
///
/// Gatekeeper decides whether to show the "downloaded from the Internet"
/// dialog from the raw `com.apple.quarantine` extended attribute, so this type
/// probes and removes that attribute directly with `getxattr(2)` and
/// `removexattr(2)`, the same way Sparkle releases an installed update. It
/// never assigns `URLResourceValues.quarantineProperties`: that setter writes
/// a quarantine record rather than removing one, and what `nil` produces
/// depends on the OS release. macOS 26.4.1 stores an empty record
/// (`0200;<time>;;`) that still triggers the dialog, macOS 15.7.4 fails with
/// an I/O error on an entry that carries no record, and macOS 27.0 removes it
/// (https://github.com/manaflow-ai/cmux/issues/13803).
///
/// Symbolic links are neither followed nor modified, so a link inside the
/// bundle cannot reach an item outside it. Entries without the attribute are
/// left untouched.
///
/// ```swift
/// let report = try ComputerUseHelperQuarantineRelease().release(treeAt: copiedHelperURL)
/// guard report.failures.isEmpty else { /* log and keep the copy */ }
/// ```
struct ComputerUseHelperQuarantineRelease {
    /// The extended attribute LaunchServices and Gatekeeper consult.
    static let attributeName = "com.apple.quarantine"

    /// One entry whose attribute could not be removed.
    struct Failure: Equatable, Sendable {
        /// The entry that still carries the attribute.
        let url: URL
        /// The `errno` reported by `removexattr(2)`.
        let code: Int32
    }

    /// The outcome of one pass over a tree.
    struct Report: Equatable, Sendable {
        /// Entries whose attribute was removed, in traversal order.
        var released: [URL] = []
        /// Entries whose attribute could not be removed.
        var failures: [Failure] = []
    }

    private enum EntryKind {
        case directory
        case symbolicLink
        case other
    }

    private let fileManager: FileManager

    /// Creates a release pass.
    /// - Parameter fileManager: Lists directory contents during traversal.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns every entry under `root`, including `root`, that carries the attribute.
    /// - Throws: `CancellationError` when the surrounding task is cancelled, or
    ///   the error that stopped a directory listing.
    func quarantinedEntries(treeAt root: URL) throws -> [URL] {
        var entries: [URL] = []
        try walk(root) { url in
            if Self.carriesAttribute(url) {
                entries.append(url)
            }
        }
        return entries
    }

    /// Removes the attribute from every entry under `root` that carries it.
    ///
    /// The pass continues after a failed removal so one bad entry does not
    /// leave the rest of the tree quarantined; each failure is reported.
    /// - Throws: `CancellationError` when the surrounding task is cancelled, or
    ///   the error that stopped a directory listing.
    func release(treeAt root: URL) throws -> Report {
        var report = Report()
        try walk(root) { url in
            guard Self.carriesAttribute(url) else { return }
            if let code = Self.removeAttribute(url) {
                report.failures.append(Failure(url: url, code: code))
            } else {
                report.released.append(url)
            }
        }
        return report
    }

    /// Visits `url` and, for a directory, everything below it. Symbolic links
    /// are skipped without being followed; an entry that vanished is skipped.
    private func walk(_ url: URL, visit: (URL) throws -> Void) throws {
        guard !Task.isCancelled else { throw CancellationError() }
        guard let kind = Self.entryKind(url) else { return }
        switch kind {
        case .symbolicLink:
            return
        case .other:
            try visit(url)
        case .directory:
            try visit(url)
            // Child URLs are built from the caller's root so a report names
            // entries in the caller's path space rather than a resolved one.
            for name in try fileManager.contentsOfDirectory(atPath: url.path) {
                try walk(url.appendingPathComponent(name), visit: visit)
            }
        }
    }

    private static func entryKind(_ url: URL) -> EntryKind? {
        url.withUnsafeFileSystemRepresentation { path -> EntryKind? in
            guard let path else { return nil }
            var status = stat()
            guard lstat(path, &status) == 0 else { return nil }
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFLNK):
                return .symbolicLink
            case mode_t(S_IFDIR):
                return .directory
            default:
                return .other
            }
        }
    }

    private static func carriesAttribute(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// Returns nil once the attribute is gone, or the `errno` of the failed call.
    private static func removeAttribute(_ url: URL) -> Int32? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            guard removexattr(path, attributeName, XATTR_NOFOLLOW) != 0 else { return nil }
            return errno
        }
    }
}
