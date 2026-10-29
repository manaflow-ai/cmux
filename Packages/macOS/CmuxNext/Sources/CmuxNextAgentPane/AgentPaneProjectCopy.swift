import Darwin
import Foundation
import CmuxNextCompat

/// Add Files to Project's disk writes (cx-ncc.67), off the main actor: a picked file can be large or
/// on a slow volume. An agent in the chat folder can write there while this runs, so nothing is
/// written through a path it could swap for a link: `.cmux/context` is opened one folder at a time
/// without following links, each copy is made exclusively inside it, and the instructions file is
/// appended through a descriptor checked to be a regular file.
nonisolated enum AgentPaneProjectCopy {
    /// The picked files that are regular files, each link resolved to the file it names (a copy is a
    /// snapshot, never a link out of the project). A folder, package or device is skipped.
    static func regularFiles(_ picks: [URL]) -> [URL] {
        picks.map { $0.resolvingSymlinksInPath() }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// Copies `sources` into `folder/.cmux/context` under import-safe names (no spaces, a number when
    /// taken) and answers the names copied. Nil when the context folder cannot be opened as a real
    /// folder inside `folder` (a link put there is refused).
    static func copy(_ sources: [URL], into folder: String) -> [String]? {
        guard let context = openContext(folder) else { return nil }
        defer { close(context) }
        return sources.compactMap { copy($0, into: context) }
    }

    /// Appends `lines` to the regular file at canonical `path`, after a newline when its text does not
    /// end in one. A link there now is refused.
    static func append(_ lines: [String], to path: String) -> Bool {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let fd = unsafe blockingOpen(path, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        // SAFETY: fstat writes one struct stat into `info`, a local.
        guard unsafe fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        var text = lines.joined(separator: "\n") + "\n"
        var last: UInt8 = 0
        // SAFETY: pread writes at most 1 byte into `last`, a local UInt8.
        if info.st_size > 0, unsafe blockingPread(fd, &last, 1, info.st_size - 1) == 1, last != UInt8(ascii: "\n") { text = "\n" + text }
        let bytes = Array(text.utf8)
        // SAFETY: write reads bytes.count bytes from the array's own storage, lent for the call.
        return unsafe write(fd, bytes, bytes.count) == bytes.count
    }

    /// `folder/.cmux/context`, opened a component at a time without following links and made when
    /// missing.
    private static func openContext(_ folder: String) -> Int32? {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        var fd = unsafe blockingOpen(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for component in [".cmux", "context"] {
            // SAFETY: mkdirat and openat read the NUL-terminated copy of the name made for each call.
            if unsafe mkdirat(fd, component, 0o755) != 0, errno != EEXIST {
                close(fd)
                return nil
            }
            let next = unsafe openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }

    /// Copies one regular file into the open context folder; nil when it is not one or the copy failed.
    private static func copy(_ source: URL, into context: Int32) -> String? {
        // Non-blocking: a FIFO swapped in for the file must not hang the copy; it fails the check below.
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let input = unsafe blockingOpen(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { return nil }
        defer { close(input) }
        var info = stat()
        // SAFETY: fstat writes one struct stat into `info`, a local.
        guard unsafe fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let name = source.lastPathComponent.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 1...999 {
            let candidate = number == 1 ? name : (ext.isEmpty ? "\(stem)-\(number)" : "\(stem)-\(number).\(ext)")
            // Exclusive and never through a link: a name taken (a link too) tries the next number.
            // SAFETY: openat reads the NUL-terminated copy of the name made for the call.
            let output = unsafe openat(context, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if output < 0 {
                if errno == EEXIST { continue }
                return nil
            }
            // SAFETY: fcopyfile copies between two open descriptors with no state object (nil).
            let copied = unsafe fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
            close(output)
            // SAFETY: unlinkat reads the NUL-terminated copy of the name made for the call.
            if !copied { unsafe unlinkat(context, candidate, 0) }
            return copied ? candidate : nil
        }
        return nil
    }
}
