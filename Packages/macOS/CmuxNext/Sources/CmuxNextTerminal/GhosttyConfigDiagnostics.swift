public import Foundation
import GhosttyNextKit

/// One finding about the user's Ghostty config (R92 diagnostics): a key
/// cmux does not apply, a keybind action cmux does not run, or a message
/// libghostty reported while it loaded the files.
public nonisolated struct GhosttyConfigDiagnostic: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// A config key in `GhosttyKeySupport.unsupported` the user set.
        case key
        /// A `keybind` action cmux does not run.
        case keybindAction = "keybind-action"
        /// libghostty could not read a line (unknown key, invalid value).
        case invalid
    }

    public var kind: Kind
    /// The key, the action name, or libghostty's message.
    public var name: String
    /// The file and 1-based line that set it, when known.
    public var file: String?
    public var line: Int?
    /// Nil for `invalid`.
    public var support: GhosttyUnsupported?

    public init(kind: Kind, name: String, file: String? = nil, line: Int? = nil, support: GhosttyUnsupported? = nil) {
        self.kind = kind
        self.name = name
        self.file = file
        self.line = line
        self.support = support
    }
}

/// What the main actor reads from the applied config for the diagnostics
/// (no file I/O): the unsupported keys with their sources, libghostty's
/// messages and the loaded files. `diagnostics()` adds the keybind lines,
/// read off the main actor.
public nonisolated struct GhosttyConfigDiagnosticsSnapshot: Sendable, Hashable {
    /// The loaded files, in load order.
    public let files: [String]
    /// Keys, ranked by file (index in `files`) and line.
    let keys: [Ranked]
    let invalid: [GhosttyConfigDiagnostic]

    struct Ranked: Sendable, Hashable {
        var rank: Int
        var line: Int
        var diagnostic: GhosttyConfigDiagnostic
    }

    init(files: [String], keys: [Ranked], invalid: [GhosttyConfigDiagnostic]) {
        self.files = files
        self.keys = keys
        self.invalid = invalid
    }

    /// A snapshot with these findings and no files to scan (tests).
    public init(diagnostics: [GhosttyConfigDiagnostic], files: [String] = []) {
        self.files = files
        keys = diagnostics.filter { $0.kind != .invalid }.enumerated().map { Ranked(rank: 0, line: $0.offset, diagnostic: $0.element) }
        invalid = diagnostics.filter { $0.kind == .invalid }
    }

    /// Every finding: the keys and the keybind lines whose action cmux does
    /// not run (`GhosttyActionSupport`), in load order, then libghostty's
    /// messages. Reads the loaded files off the main actor.
    @concurrent public func diagnostics() async -> [GhosttyConfigDiagnostic] {
        var found = keys
        for (rank, file) in files.enumerated() {
            // concurrency-allow: @concurrent, so this read never runs on the main actor.
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for (line, action) in GhosttyRuntime.unsupportedKeybindActions(in: text) {
                found.append(Ranked(rank: rank, line: line, diagnostic: GhosttyConfigDiagnostic(
                    kind: .keybindAction, name: action.name, file: file, line: line, support: action.support)))
            }
        }
        found.sort { ($0.rank, $0.line, $0.diagnostic.name) < ($1.rank, $1.line, $1.diagnostic.name) }
        return found.map(\.diagnostic) + invalid
    }
}

extension GhosttyRuntime {
    /// The applied config's diagnostics snapshot; nil when none loaded.
    public var configDiagnosticsSnapshot: GhosttyConfigDiagnosticsSnapshot? {
        guard let config else { return nil }
        return Self.snapshot(of: config)
    }

    /// The diagnostics of the file at `path` loaded alone with its includes,
    /// as libghostty loads a config file (tests).
    public static func configDiagnostics(configFile path: String) async -> [GhosttyConfigDiagnostic] {
        guard let config = ghostty_config_new() else { return [] }
        ghostty_config_load_file(config, path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        let snapshot = snapshot(of: config)
        ghostty_config_free(config)
        return await snapshot.diagnostics()
    }

    /// Unsupported keys the user's files set (libghostty's own source of
    /// each key, so includes and the last assignment count as in Ghostty;
    /// cmux's built-in defaults are not files and never show), libghostty's
    /// messages and the loaded files.
    static func snapshot(of config: ghostty_config_t) -> GhosttyConfigDiagnosticsSnapshot {
        let files = loadedFiles(of: config)
        var order: [String: Int] = [:]
        for (index, file) in files.enumerated() where order[resolved(file)] == nil {
            order[resolved(file)] = index
        }
        var keys: [GhosttyConfigDiagnosticsSnapshot.Ranked] = []
        for (key, support) in GhosttyKeySupport.unsupported {
            var source = ghostty_config_source_s()
            let found = key.withCString { ghostty_config_key_source(config, $0, UInt(key.utf8.count), &source) }
            guard found, let pointer = source.path else { continue }
            let path = String(cString: pointer)
            guard let rank = order[resolved(path)] else { continue }
            let line = Int(source.line)
            keys.append(.init(rank: rank, line: line, diagnostic: GhosttyConfigDiagnostic(kind: .key, name: key, file: path, line: line,
                                                                                         support: support)))
        }
        let invalid = (0..<ghostty_config_diagnostics_count(config)).compactMap { index in
            ghostty_config_get_diagnostic(config, index).message.map {
                GhosttyConfigDiagnostic(kind: .invalid, name: String(cString: $0))
            }
        }
        return GhosttyConfigDiagnosticsSnapshot(files: files, keys: keys, invalid: invalid)
    }

    /// The `keybind` lines of one file whose action is in
    /// `GhosttyActionSupport.unsupported`, by 1-based line. Lines as
    /// Ghostty's config reader takes them (trimmed, `#` comments, one pair
    /// of quotes around the value); the action after the trigger as its
    /// binding parser finds it (flags, then the first `=` that is not
    /// followed by `+` or `=`).
    nonisolated static func unsupportedKeybindActions(in text: String) -> [(Int, (name: String, support: GhosttyUnsupported))] {
        var found: [(Int, (name: String, support: GhosttyUnsupported))] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "keybind" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard let action = keybindAction(value) else { continue }
            let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
            if let support = GhosttyActionSupport.unsupported[name] { found.append((index + 1, (name, support))) }
        }
        return found
    }

    /// The action of one `keybind` value, or nil (`clear`, no action).
    private nonisolated static func keybindAction(_ value: String) -> String? {
        var input = Substring(value)
        while let colon = input.firstIndex(of: ":"),
              ["global", "all", "unconsumed", "performable"].contains(String(input[..<colon])) {
            input = input[input.index(after: colon)...]
        }
        var search = input.startIndex
        while let equals = input[search...].firstIndex(of: "=") {
            let next = input.index(after: equals)
            if next < input.endIndex, input[next] == "+" || input[next] == "=" {
                search = next
                continue
            }
            let action = input[next...].trimmingCharacters(in: .whitespaces)
            return action.isEmpty ? nil : action
        }
        return nil
    }

    /// One spelling per file (`/var` and `/private/var` are the same file).
    private nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
