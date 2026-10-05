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

extension GhosttyRuntime {
    /// The diagnostics of the applied config; empty when none loaded.
    public var configDiagnosticsReport: [GhosttyConfigDiagnostic] {
        guard let config else { return [] }
        return Self.diagnostics(of: config)
    }

    /// The diagnostics of the file at `path` loaded alone with its includes,
    /// as libghostty loads a config file (tests).
    public static func configDiagnostics(configFile path: String) -> [GhosttyConfigDiagnostic] {
        guard let config = ghostty_config_new() else { return [] }
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        return diagnostics(of: config)
    }

    /// Unsupported keys the user's files set (libghostty's own source of
    /// each key, so includes and the last assignment count as in Ghostty;
    /// cmux's built-in defaults are not files and never show), in load
    /// order, then libghostty's messages.
    static func diagnostics(of config: ghostty_config_t) -> [GhosttyConfigDiagnostic] {
        var order: [String: Int] = [:]
        for (index, file) in loadedFiles(of: config).enumerated() where order[resolved(file)] == nil {
            order[resolved(file)] = index
        }
        var keys: [(rank: Int, line: Int, diagnostic: GhosttyConfigDiagnostic)] = []
        for (key, support) in GhosttyKeySupport.unsupported {
            var source = ghostty_config_source_s()
            let found = key.withCString { ghostty_config_key_source(config, $0, UInt(key.utf8.count), &source) }
            guard found, let pointer = source.path else { continue }
            let path = String(cString: pointer)
            guard let rank = order[resolved(path)] else { continue }
            let line = Int(source.line)
            keys.append((rank, line, GhosttyConfigDiagnostic(kind: .key, name: key, file: path, line: line, support: support)))
        }
        keys.sort { ($0.rank, $0.line, $0.diagnostic.name) < ($1.rank, $1.line, $1.diagnostic.name) }
        let invalid = (0..<ghostty_config_diagnostics_count(config)).compactMap { index in
            ghostty_config_get_diagnostic(config, index).message.map {
                GhosttyConfigDiagnostic(kind: .invalid, name: String(cString: $0))
            }
        }
        return keys.map(\.diagnostic) + invalid
    }

    /// One spelling per file (`/var` and `/private/var` are the same file).
    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
