internal import Darwin
internal import Foundation

/// The one place a `.url` sidebar file is read and parsed.
///
/// Two questions are asked of the same file — "which URL does it name" (``CustomSidebarWebSource``)
/// and "why not" (``CustomSidebarWebSourceProblem``) — and they must never disagree, or validation
/// approves a file the renderer then refuses. Both go through this reader, so the parse exists once.
///
/// ## Why the read is bounded
///
/// A `.url` file is untrusted input: it arrives by hand or by dragging a page out of a browser, and
/// it is re-read on every resolution, which is every mount and every `cmux sidebar reload`. Reading
/// it whole into a `String` makes an arbitrarily large file fully resident before anything judges
/// it. A shortcut file that needs more than ``maximumByteCount`` is not a shortcut file, so the
/// reader stops at the limit and reports the size rather than growing to fit.
///
/// The read takes at most the limit plus one byte: the extra byte is what distinguishes a file that
/// exactly fills the limit from one that overflows it, without reading any of the overflow.
enum CustomSidebarURLFileReader {
    /// The largest `.url` file that will be read, in bytes.
    ///
    /// Generous by design. A browser-written `[InternetShortcut]` with a long query string and every
    /// optional key is a few hundred bytes, so nothing an author can produce on purpose is near
    /// this, and anything past it is a file that was renamed by mistake.
    static let maximumByteCount = 64 * 1024

    /// What reading a `.url` file yielded.
    enum Outcome: Equatable {
        /// The bytes could not be read, or are not UTF-8 text.
        case unreadable
        /// The file is larger than ``maximumByteCount``, so it was not parsed.
        case tooLarge
        /// The file's candidate lines, in order. May be empty.
        case lines([String])
    }

    /// Reads a regular `.url` file and returns its candidate lines, bounded.
    ///
    /// Blank lines, `[Section]` headers, and `#` comments are dropped, and a Windows `URL=` prefix
    /// is stripped, since that is what a browser writes. What survives is the sequence of strings a
    /// caller should try to parse as a URL, in the order the file gave them — which is what makes
    /// "first loadable URL wins" and the diagnostic precedence two readings of one list rather than
    /// two parsers that have to be kept in step.
    ///
    /// FIFOs, sockets, devices, and directories are rejected from descriptor metadata before a read.
    /// The descriptor is opened nonblocking so even a FIFO with no writer returns immediately. Normal
    /// symlinks remain supported because `open` follows the link and `fstat` checks its target.
    ///
    /// - Parameter fileURL: The `.url` file to read.
    static func read(fileURL: URL) -> Outcome {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            return .unreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // One byte past the limit: enough to tell "exactly at the limit" from "over it" without
        // reading, or holding, any of the overflow.
        guard let data = try? handle.read(upToCount: maximumByteCount + 1) else { return .unreadable }
        if data.count > maximumByteCount { return .tooLarge }
        guard let contents = String(data: data, encoding: .utf8) else { return .unreadable }

        var lines: [String] = []
        // `enumerateLines` walks the string once and hands each line over in turn, so no array of
        // every line in the file is ever built — only the candidates, of which a real shortcut file
        // has one or two.
        contents.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("[") || trimmed.hasPrefix("#") { return }
            let candidate = trimmed.hasPrefix("URL=") ? String(trimmed.dropFirst(4)) : trimmed
            let value = candidate.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return }
            lines.append(value)
        }
        return .lines(lines)
    }
}
