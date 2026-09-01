public import Foundation

/// A canned directory in a demonstration terminal's fake filesystem.
///
/// The tree is immutable session data: `ls`, `cd`, `pwd`, and `cat` compose
/// over it so the reviewer can move around a plausible project checkout.
public struct MobileDemoDirectory: Equatable, Sendable {
    /// Entries in display order.
    public let entries: [MobileDemoFileSystemEntry]

    /// Creates a directory with the given entries.
    public init(_ entries: [MobileDemoFileSystemEntry]) {
        self.entries = entries
    }

    /// The subdirectory with the given name, if any.
    func subdirectory(named name: String) -> MobileDemoDirectory? {
        for case let .directory(entryName, directory) in entries where entryName == name {
            return directory
        }
        return nil
    }

    /// The file entry with the given name, if any.
    func file(named name: String) -> MobileDemoFileSystemEntry? {
        entries.first {
            if case let .file(entryName, _) = $0 { return entryName == name }
            return false
        }
    }
}

/// One entry of a demo filesystem directory.
public enum MobileDemoFileSystemEntry: Equatable, Sendable {
    /// A nested directory.
    case directory(name: String, MobileDemoDirectory)
    /// A file, with optional plain-text `cat` contents.
    case file(name: String, contents: String?)

    /// The entry's display name.
    public var name: String {
        switch self {
        case let .directory(name, _): name
        case let .file(name, _): name
        }
    }
}

/// One demonstration terminal's canned starting state.
///
/// `transcript` is raw VT/ANSI text shown as the terminal's existing history;
/// the filesystem and directory names feed the interactive `cd`/`ls`/`pwd`/
/// `cat` session that follows it.
public struct MobileDemoTerminalScript: Equatable, Sendable {
    /// The terminal surface identifier this script backs.
    public let surfaceID: String
    /// Canned VT/ANSI history rendered above the first prompt.
    public let transcript: String
    /// The absolute path of the session's starting directory (`pwd` at the
    /// root, e.g. `/Users/demo/code/api-server`).
    public let workingDirectory: String
    /// The prompt spelling of the starting directory (e.g. `~/code/api-server`).
    public let displayDirectory: String
    /// The fake project tree rooted at ``workingDirectory``.
    public let fileSystem: MobileDemoDirectory

    /// Creates a demo terminal script.
    public init(
        surfaceID: String,
        transcript: String,
        workingDirectory: String,
        displayDirectory: String,
        fileSystem: MobileDemoDirectory = MobileDemoDirectory([])
    ) {
        self.surfaceID = surfaceID
        self.transcript = transcript
        self.workingDirectory = workingDirectory
        self.displayDirectory = displayDirectory
        self.fileSystem = fileSystem
    }

    /// The shell prompt for a working path under the root (empty = root).
    func prompt(atPath path: [String]) -> String {
        let display = ([displayDirectory] + path).joined(separator: "/")
        return "\u{1B}[1;32mdemo@demo-mac\u{1B}[0m \u{1B}[1;36m\(display)\u{1B}[0m % "
    }

    /// The absolute `pwd` for a working path under the root.
    func absolutePath(atPath path: [String]) -> String {
        ([workingDirectory] + path).joined(separator: "/")
    }
}

/// A local, deterministic PTY simulacrum for demonstration terminals.
///
/// The engine renders canned session history and then behaves like a minimal
/// line-disciplined shell: typed characters echo immediately, backspace
/// erases, Ctrl-C aborts the line, and Enter runs a command. The engine owns
/// only the line discipline and the filesystem/session commands (`cd`, `ls`,
/// `pwd`, `cat`, `clear`) whose behavior depends on per-terminal state; every
/// other command resolves through ``MobileDemoCommandCatalog``, the single
/// place showcase commands are added. All output is plain VT bytes delivered
/// through the same output stream the real terminal pipeline uses; nothing
/// here talks to a network.
@MainActor
public final class MobileDemoTerminalEngine {
    /// Bounds retained per-terminal history so an adversarial typing session
    /// cannot grow memory without limit. Old history simply scrolls away.
    static let maximumTranscriptUTF8Bytes = 256 * 1_024

    private struct SessionState {
        var script: MobileDemoTerminalScript
        /// Everything already "on screen" before the current prompt+line.
        var transcript: String
        /// The current, not-yet-executed input line.
        var lineBuffer: String
        /// The working directory as path components under the script's root.
        var path: [String] = []
    }

    private var sessionsBySurfaceID: [String: SessionState] = [:]
    private let now: @Sendable () -> Date

    /// Creates an engine over the given terminal scripts.
    /// - Parameters:
    ///   - scripts: One script per demo terminal surface.
    ///   - now: Clock used by time-dependent showcase commands; injected for
    ///     deterministic tests.
    public init(
        scripts: [MobileDemoTerminalScript],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        for script in scripts {
            sessionsBySurfaceID[script.surfaceID] = SessionState(
                script: script,
                transcript: script.transcript,
                lineBuffer: ""
            )
        }
    }

    /// Whether this engine owns the given terminal surface.
    public func ownsSurface(_ surfaceID: String) -> Bool {
        sessionsBySurfaceID[surfaceID] != nil
    }

    /// The full-screen replay for a (re)mounted surface: canned history plus
    /// the prompt and any un-executed typed input, so a remount restores
    /// exactly what the user last saw.
    public func replayBytes(surfaceID: String) -> Data? {
        guard let session = sessionsBySurfaceID[surfaceID] else { return nil }
        let screen = session.transcript
            + session.script.prompt(atPath: session.path)
            + session.lineBuffer
        return Data(screen.utf8)
    }

    /// Feeds typed input into the simulated shell and returns the bytes to
    /// echo back to the terminal view (echoed characters, erase sequences,
    /// command output, fresh prompts). Returns `nil` for surfaces this engine
    /// does not own.
    public func inputBytes(_ text: String, surfaceID: String) -> Data? {
        guard var session = sessionsBySurfaceID[surfaceID] else { return nil }
        var output = ""
        var scalars = Substring(text).unicodeScalars[...]

        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            switch scalar {
            case "\r", "\n":
                // Swallow the LF of a CRLF pair so one Enter runs one command.
                if scalar == "\r", scalars.first == "\n" {
                    scalars = scalars.dropFirst()
                }
                output += executeLine(&session)
            case "\u{7F}", "\u{08}":
                if !session.lineBuffer.isEmpty {
                    session.lineBuffer.removeLast()
                    output += "\u{08} \u{08}"
                }
            case "\u{03}":
                // Ctrl-C: abort the line like a shell.
                session.lineBuffer = ""
                output += "^C\r\n" + session.script.prompt(atPath: session.path)
                appendToTranscript(&session, "^C\r\n")
            case "\u{0C}":
                // Ctrl-L: clear the screen, keep the typed line.
                session.transcript = ""
                output += "\u{1B}[2J\u{1B}[H"
                    + session.script.prompt(atPath: session.path)
                    + session.lineBuffer
            case "\u{1B}":
                // Swallow escape sequences (arrow keys, etc.) instead of
                // echoing raw control bytes into the canned session.
                skipEscapeSequence(&scalars)
            default:
                if scalar.properties.generalCategory == .control {
                    continue
                }
                session.lineBuffer.unicodeScalars.append(scalar)
                output.unicodeScalars.append(scalar)
            }
        }

        sessionsBySurfaceID[surfaceID] = session
        guard !output.isEmpty else { return Data() }
        return Data(output.utf8)
    }

    // MARK: Command execution

    /// Runs the buffered line: engine-owned filesystem/session commands
    /// first, then the showcase catalog. Returns the bytes to echo (newline,
    /// command output, next prompt) and folds the exchange into the
    /// transcript so replay stays consistent.
    private func executeLine(_ session: inout SessionState) -> String {
        let line = session.lineBuffer
        session.lineBuffer = ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            appendToTranscript(&session, line + "\r\n")
            return "\r\n" + session.script.prompt(atPath: session.path)
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let command = String(parts.first ?? "")
        let argument = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : ""

        let body: String
        switch command {
        case "cd":
            body = changeDirectory(&session, argument: argument)
        case "ls":
            body = listDirectory(session, argument: argument)
        case "pwd":
            body = session.script.absolutePath(atPath: session.path) + "\r\n"
        case "cat":
            body = catFile(session, argument: argument)
        case "clear":
            session.transcript = ""
            return "\u{1B}[2J\u{1B}[H" + session.script.prompt(atPath: session.path)
        default:
            body = MobileDemoCommandCatalog.response(
                command: command,
                context: MobileDemoCommandCatalog.Context(
                    arguments: argument,
                    workingDirectory: session.script.absolutePath(atPath: session.path),
                    now: now()
                )
            ) ?? "zsh: command not found: \(command)\r\n"
        }

        let echoed = "\r\n" + body
        appendToTranscript(&session, line + echoed)
        return echoed + session.script.prompt(atPath: session.path)
    }

    // MARK: Filesystem commands

    /// Resolves a user path argument against the session's working path.
    /// Supports `~` (root), `.`, `..`, and `/`-separated relative segments.
    /// Returns the resolved components under the root, or `nil` when a
    /// segment names no directory.
    private func resolveDirectoryPath(
        _ argument: String,
        session: SessionState
    ) -> [String]? {
        var path: [String]
        var segments = argument.split(separator: "/").map(String.init)
        if argument.hasPrefix("~") {
            path = []
            if segments.first == "~" { segments.removeFirst() }
        } else {
            path = session.path
        }
        for segment in segments {
            switch segment {
            case ".":
                continue
            case "..":
                if !path.isEmpty { path.removeLast() }
            default:
                guard directory(at: path, in: session)?
                    .subdirectory(named: segment) != nil else { return nil }
                path.append(segment)
            }
        }
        return path
    }

    /// The directory node at the given components, or `nil` off-tree.
    private func directory(at path: [String], in session: SessionState) -> MobileDemoDirectory? {
        var node = session.script.fileSystem
        for segment in path {
            guard let next = node.subdirectory(named: segment) else { return nil }
            node = next
        }
        return node
    }

    private func changeDirectory(_ session: inout SessionState, argument: String) -> String {
        guard !argument.isEmpty, argument != "~" else {
            session.path = []
            return ""
        }
        guard let resolved = resolveDirectoryPath(argument, session: session) else {
            return "cd: no such file or directory: \(argument)\r\n"
        }
        session.path = resolved
        return ""
    }

    private func listDirectory(_ session: SessionState, argument: String) -> String {
        let target: MobileDemoDirectory?
        if argument.isEmpty {
            target = directory(at: session.path, in: session)
        } else if let resolved = resolveDirectoryPath(argument, session: session) {
            target = directory(at: resolved, in: session)
        } else {
            return "ls: \(argument): No such file or directory\r\n"
        }
        guard let entries = target?.entries, !entries.isEmpty else { return "" }
        let rendered = entries.map { entry in
            switch entry {
            case let .directory(name, _):
                "\u{1B}[1;34m\(name)\u{1B}[0m"
            case let .file(name, _):
                name
            }
        }
        return rendered.joined(separator: "  ") + "\r\n"
    }

    private func catFile(_ session: SessionState, argument: String) -> String {
        guard !argument.isEmpty else { return "" }
        var segments = argument.split(separator: "/").map(String.init)
        guard let fileName = segments.popLast() else {
            return "cat: \(argument): No such file or directory\r\n"
        }
        let parentPath: [String]?
        if segments.isEmpty, !argument.hasPrefix("~") {
            parentPath = session.path
        } else {
            let parentArgument = argument.hasPrefix("~") && segments == ["~"]
                ? "~"
                : segments.joined(separator: "/")
            parentPath = resolveDirectoryPath(parentArgument, session: session)
        }
        guard let parentPath,
              let parent = directory(at: parentPath, in: session),
              case let .file(_, contents)? = parent.file(named: fileName) else {
            return "cat: \(argument): No such file or directory\r\n"
        }
        guard let contents else {
            return "cat: \(argument): Permission denied\r\n"
        }
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        return normalized.hasSuffix("\r\n") ? normalized : normalized + "\r\n"
    }

    // MARK: Transcript bookkeeping

    private func appendToTranscript(_ session: inout SessionState, _ text: String) {
        session.transcript += text
        // Trim from the front on overflow; the terminal only replays what a
        // real scrollback would still retain.
        while session.transcript.utf8.count > Self.maximumTranscriptUTF8Bytes {
            session.transcript.removeFirst(session.transcript.count / 4)
        }
    }

    /// Consumes one ESC-initiated sequence (CSI/SS3/two-byte) from the input.
    private func skipEscapeSequence(_ scalars: inout Substring.UnicodeScalarView.SubSequence) {
        guard let introducer = scalars.first else { return }
        scalars = scalars.dropFirst()
        switch introducer {
        case "[":
            // CSI: parameter bytes 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
            while let byte = scalars.first {
                scalars = scalars.dropFirst()
                if (0x40...0x7E).contains(byte.value) { break }
            }
        case "O":
            // SS3: exactly one final byte.
            if scalars.first != nil { scalars = scalars.dropFirst() }
        default:
            break
        }
    }
}
