public import Foundation

/// Tab in shell mode (`shell.complete`, webviews `shell/`): the user's own shell lists what can
/// follow the text before the caret. Nothing here knows a command: zsh runs its completion system
/// (`compinit`, the same functions an interactive zsh uses, captured through `zsh/zpty`), bash
/// runs `compgen`, fish runs `complete -C`. Any other shell falls back to `/bin/zsh`.
///
/// Each completion is one short-lived login shell in the chat's folder, in its own process group,
/// stdin from /dev/null, killed at ``deadline``. The shell writes its candidates between two NUL
/// bytes, so whatever a login profile prints is ignored. At most ``maximumCandidates`` come back.
public nonisolated struct AgentPaneShellCompletion: Sendable {
    public static let maximumCandidates = 200
    public static let maximumLine = 4096
    static let maximumOutput = 512 << 10
    public static let deadline: Duration = .seconds(4)

    /// The word the caret is in: its UTF-16 start in the line (the page's field offsets), its text
    /// as typed (quotes and backslashes kept), and whether it names a command.
    public nonisolated struct Word: Equatable, Sendable {
        public var start: Int
        public var text: String
        public var commandPosition: Bool
    }

    public nonisolated struct Candidate: Equatable, Sendable {
        /// What replaces the word, escaped for the shell.
        public var value: String
        /// The shell's description of it (zsh `--` text, fish's second column).
        public var detail: String?
    }

    public nonisolated struct Result: Equatable, Sendable {
        /// UTF-16 offset in the line where the replaced word starts; it ends at the caret.
        public var start: Int
        public var candidates: [Candidate]
        public var truncated: Bool
    }

    public nonisolated enum Failure: Error, Equatable, Sendable {
        case folderMissing
        case spawnFailed(Int32)
        case timedOut
    }

    nonisolated enum Engine: Equatable, Sendable {
        case zsh, bash, fish
    }

    private let shell: String
    private let engine: Engine
    private let environment: [String: String]
    private let home: String
    /// When the shell is killed (``deadline`` in the app; tests that do not test it pass a long one).
    private let timeout: Duration

    public init(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        timeout: Duration = AgentPaneShellCompletion.deadline
    ) {
        let candidate = shell ?? ""
        let usable = candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate)
        let name = (candidate as NSString).lastPathComponent
        switch name {
        case "bash" where usable: (self.shell, engine) = (candidate, .bash)
        case "fish" where usable: (self.shell, engine) = (candidate, .fish)
        case "zsh" where usable: (self.shell, engine) = (candidate, .zsh)
        default: (self.shell, engine) = ("/bin/zsh", .zsh)
        }
        var environment = environment
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        self.environment = environment
        self.home = home
        self.timeout = timeout
    }

    /// The candidates for the word before the end of `line` (the text before the caret).
    public func complete(_ line: String, cwd: String?) async throws(Failure) -> Result {
        let folder = cwd ?? home
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .folderMissing
        }
        let word = Self.word(in: line)
        let (arguments, extra) = invocation(line: line, word: word)
        let output = try await CompletionProcess.run(path: shell, arguments: arguments, environment: environment.merging(extra) { $1 },
                                                     folder: folder, timeout: timeout)
        let parsed = Self.parse(output, engine: engine)
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for item in parsed {
            // zsh's completion system quotes its matches itself; bash and fish print them raw.
            let value = engine == .zsh ? item.value : Self.escape(item.value, word: word.text)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            candidates.append(Candidate(value: value, detail: item.detail))
        }
        let truncated = candidates.count > Self.maximumCandidates
        return Result(start: word.start, candidates: Array(candidates.prefix(Self.maximumCandidates)), truncated: truncated)
    }

    // MARK: Shells

    private func invocation(line: String, word: Word) -> (arguments: [String], environment: [String: String]) {
        switch engine {
        case .zsh:
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "cmux-next", directoryHint: .isDirectory)
            if let caches { try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true) }
            let dump = environment["CMUX_COMPLETE_DUMP"]
                ?? caches?.appending(path: "zcompdump-shell-mode").path
                ?? "\(home)/.zcompdump-cmux-shell-mode"
            return ([shell, "-l", "-c", Self.zshDriver, "zsh", line, shell],
                    ["CMUX_COMPLETE_SETUP": Self.zshSetup, "CMUX_COMPLETE_DUMP": dump])
        case .bash:
            return ([shell, "-l", "-c", Self.bashScript, "bash", Self.unquoted(word.text), word.commandPosition ? "1" : "0"], [:])
        case .fish:
            return ([shell, "-l", "-c", Self.fishScript, line], [:])
        }
    }

    // MARK: Parsing

    /// The lines between the first two NUL bytes, without carriage returns or escape sequences.
    nonisolated static func parse(_ output: Data, engine: Engine) -> [(value: String, detail: String?)] {
        let parts = output.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return [] }
        let text = String(decoding: parts[1], as: UTF8.self)
        var items: [(value: String, detail: String?)] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = stripEscapes(String(raw)).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let separator = engine == .fish ? "\t" : " -- "
            if let range = line.range(of: separator) {
                let detail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                items.append((String(line[..<range.lowerBound]), detail.isEmpty ? nil : detail))
            } else {
                items.append((line, nil))
            }
        }
        return items
    }

    /// Removes terminal control sequences (CSI and two-byte escapes) a pty may print.
    nonisolated static func stripEscapes(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var result = ""
        var scalars = line.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else { result.unicodeScalars.append(scalar); continue }
            guard let next = scalars.next() else { break }
            guard next == "[" else { continue }
            while let byte = scalars.next(), !(0x40...0x7E).contains(byte.value) {}
        }
        return result
    }

    // MARK: Words

    /// Splits the text before the caret as the shell would for its last word: unquoted spaces end
    /// a word; `|`, `;`, `&` and `(` also start a new command, `<` and `>` a file name.
    nonisolated static func word(in line: String) -> Word {
        var start = 0
        var offset = 0
        var text = ""
        var commandPosition = true
        var single = false
        var double = false
        var escaped = false
        for scalar in line.unicodeScalars {
            let width = scalar.utf16.count
            defer { offset += width }
            if escaped { escaped = false; text.unicodeScalars.append(scalar); continue }
            if single {
                if scalar == "'" { single = false }
                text.unicodeScalars.append(scalar)
                continue
            }
            if scalar == "\\" { escaped = true; text.unicodeScalars.append(scalar); continue }
            if double {
                if scalar == "\"" { double = false }
                text.unicodeScalars.append(scalar)
                continue
            }
            switch scalar {
            case "'": single = true; text.unicodeScalars.append(scalar)
            case "\"": double = true; text.unicodeScalars.append(scalar)
            case " ", "\t", "\n":
                if !text.isEmpty { commandPosition = false }
                text = ""
                start = offset + width
            case "|", ";", "&", "(":
                text = ""
                commandPosition = true
                start = offset + width
            case "<", ">":
                text = ""
                commandPosition = false
                start = offset + width
            default: text.unicodeScalars.append(scalar)
            }
        }
        return Word(start: start, text: text, commandPosition: commandPosition)
    }

    /// `word` without its opening quote and backslash escapes, as `compgen` wants it.
    nonisolated static func unquoted(_ word: String) -> String {
        var result = ""
        var escaped = false
        for (index, character) in word.enumerated() {
            if index == 0, character == "\"" || character == "'" { continue }
            if escaped { result.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" || character == "'" { continue }
            result.append(character)
        }
        return result
    }

    private nonisolated static let special = Set(" \t\n\\'\"$`;&|<>()*?[]#!{}")

    /// A raw candidate as the shell reads it back: special characters get a backslash, a leading
    /// `~` stays a home folder, and inside a quote the word keeps its quote and nothing is escaped.
    nonisolated static func escape(_ candidate: String, word: String) -> String {
        if let quote = word.first, quote == "\"" || quote == "'" {
            return candidate.first == quote ? candidate : String(quote) + candidate
        }
        var result = ""
        for (index, character) in candidate.enumerated() {
            if special.contains(character) || (character == "~" && index > 0) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

extension AgentPaneModel {
    /// `shell.complete`: the user's shell's candidates for the word before the caret, as
    /// `{start, candidates: [{value, detail?}], truncated?}`. Only after a real gesture.
    func respondToShellComplete(line: String, cwd: String?) async -> [String: Any] {
        guard transport.gestures.consume() else {
            return AgentPaneReply.failure(code: "shell.gesture_required", message: Self.shellGestureMessage)
        }
        do {
            let result = try await shell.completion.complete(line, cwd: cwd)
            var value: [String: Any] = [
                "start": result.start,
                "candidates": result.candidates.map { candidate -> [String: Any] in
                    var entry: [String: Any] = ["value": candidate.value]
                    if let detail = candidate.detail { entry["detail"] = detail }
                    return entry
                },
            ]
            if result.truncated { value["truncated"] = true }
            return AgentPaneReply.success(value)
        } catch {
            switch error {
            case .timedOut:
                // The shell started and ran past the deadline: a timeout, never "Could not start".
                return AgentPaneReply.failure(code: "shell.timed_out", message: Self.shellCompletionTimedOutMessage)
            case .folderMissing:
                return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(AgentPaneShell.Failure.folderMissing))
            case .spawnFailed(let code):
                return AgentPaneReply.failure(code: "shell.failed", message: Self.shellFailureMessage(AgentPaneShell.Failure.spawnFailed(code)))
            }
        }
    }
}
