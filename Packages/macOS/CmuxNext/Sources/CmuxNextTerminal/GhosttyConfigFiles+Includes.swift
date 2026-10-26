import CmuxNextCompat
public import Foundation

nonisolated extension GhosttyConfigFiles {
    /// How ``read(_:reader:)`` reaches the file system; tests pass their own.
    public nonisolated struct Reader: Sendable {
        /// One path as libghostty's open and stat see it.
        public nonisolated enum Entry: Sendable, Equatable {
            /// Nothing at the path (`ENOENT`).
            case missing
            /// A regular file and its bytes.
            case file(Data)
            /// Anything else: a directory, an unreadable or too large file.
            case other
        }

        /// A relative include's path, resolved as libghostty's `realPathFile` resolves it.
        public nonisolated enum Resolved: Sendable, Equatable {
            /// The path with every symbolic link resolved.
            case resolved(String)
            /// Nothing at the path (`ENOENT`): libghostty keeps it as written, made absolute.
            case missing
            /// Another error: libghostty reports it.
            case failed
        }

        let entry: @Sendable (String) -> Entry
        let resolve: @Sendable (String) -> Resolved

        public init(entry: @escaping @Sendable (String) -> Entry, resolve: @escaping @Sendable (String) -> Resolved) {
            (self.entry, self.resolve) = (entry, resolve)
        }

        /// The disk, through checked blocking calls.
        public static let disk = Reader(entry: { diskEntry($0) }, resolve: { diskResolve($0) })

        private static func diskEntry(_ path: String) -> Entry {
            blockingCall(.fileIO) { () -> Entry in
                // Non-blocking, so a FIFO at the path never holds the lane; a regular file reads as usual.
                let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { return errno == ENOENT ? .missing : .other }
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_size <= GhosttyConfigFiles.maximumFileBytes else { return .other }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                do { return .file(try handle.blockingReadToEnd() ?? Data()) } catch { return .other }
            }
        }

        private static func diskResolve(_ path: String) -> Resolved {
            blockingCall(.fileIO) { () -> Resolved in
                guard let resolved = realpath(path, nil) else { return errno == ENOENT ? .missing : .failed }
                defer { free(resolved) }
                return .resolved(String(cString: resolved))
            }
        }
    }

    /// One `config-file` value as libghostty keeps it once the file that set it has loaded
    /// (`Path.parse` and `Path.expand`, ghostty-next `src/config/path.zig`).
    nonisolated struct Include: Equatable {
        let path: String
        /// Written with a leading `?`: a missing file is skipped silently.
        let optional: Bool
    }

    /// The longest line libghostty's `LineIterator` reads (`MAX_LINE_SIZE` less the `--` it prepends);
    /// a longer one ends its read of the file.
    static let maximumLineBytes = 4094

    /// The `config-file` values of one file, expanded against its path, in order, as libghostty's
    /// `LineIterator` and `RepeatablePath.parseCLI` read them (ghostty-next `src/cli/args.zig`).
    ///
    /// - Returns: The values; nil when libghostty would not take them as plain values (an empty value,
    ///   which clears the list; the key with no `=`; a line it cannot hold; a path it cannot expand).
    static func includes(in contents: Data, of path: String, home: String?, reader: Reader) -> [Include]? {
        var bytes = [UInt8](contents)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let key = Array("config-file".utf8)
        var found: [Include] = []
        for raw in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            guard raw.count < maximumLineBytes else { return nil }
            let line = trimmed(raw, " \t\r")
            guard let first = line.first, first != UInt8(ascii: "#") else { continue }
            guard let equals = line.firstIndex(of: UInt8(ascii: "=")) else {
                if line.elementsEqual(key) { return nil }
                continue
            }
            guard trimmed(line[..<equals], " \t").elementsEqual(key) else { continue }
            var value = unquoted(trimmed(line[line.index(after: equals)...], " \t"))
            guard !value.isEmpty else { return nil }
            let optional = value.first == UInt8(ascii: "?")
            if optional { value = unquoted(value.dropFirst()) }
            guard !value.isEmpty else { continue }  // `?` or `?""`: libghostty ignores it
            guard let written = String(bytes: value, encoding: .utf8),
                  let expanded = expand(written, base: directory(of: path), home: home, reader: reader) else { return nil }
            found.append(Include(path: expanded, optional: optional))
        }
        return found
    }

    /// `Path.expand`: an absolute path as written, `~/` from the home directory, anything else against
    /// the including file's directory (resolved when it exists, else made absolute as written).
    private static func expand(_ path: String, base: String, home: String?, reader: Reader) -> String? {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~/") { return home.map { $0 + path.dropFirst() } }
        let full = joined(base, path)
        switch reader.resolve(full) {
        case .resolved(let resolved): return resolved
        case .missing: return lexical(full)
        case .failed: return nil
        }
    }

    /// `std.fs.path.dirname` of an absolute path.
    private static func directory(of path: String) -> String {
        var trimmedPath = Substring(path)
        while trimmedPath.count > 1, trimmedPath.hasSuffix("/") { trimmedPath = trimmedPath.dropLast() }
        guard let slash = trimmedPath.lastIndex(of: "/"), slash != trimmedPath.startIndex else { return "/" }
        return String(trimmedPath[..<slash])
    }

    /// `std.fs.path.resolve` of one absolute path: `.` and `..` removed, separators collapsed.
    private static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func trimmed(_ bytes: ArraySlice<UInt8>, _ characters: String) -> ArraySlice<UInt8> {
        let set = Set(characters.utf8)
        guard let start = bytes.firstIndex(where: { !set.contains($0) }), let end = bytes.lastIndex(where: { !set.contains($0) }) else {
            return []
        }
        return bytes[start...end]
    }

    /// One pair of surrounding double quotes removed.
    private static func unquoted(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let quote = UInt8(ascii: "\"")
        guard bytes.count >= 2, bytes.first == quote, bytes.last == quote else { return bytes }
        return bytes.dropFirst().dropLast()
    }
}
