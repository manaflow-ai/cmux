public import Foundation

/// What the native "Enable harness" sheet shows for a folder harness profile
/// (BRING-YOUR-OWN-HARNESS H4): acpmux's own prompt (`_acpmux/harness_enable {folder, id}` over
/// the unix socket), never text from the page. The relay sends the prompt's `sha256` only after the
/// user pressed Enable on this sheet, so a confirmation covers exactly the bytes the sheet showed.
public nonisolated struct AgentPaneHarnessEnablePrompt: Equatable, Sendable {
    /// One env key and where its value comes from. Plain values are shown; Keychain items and
    /// login variables are named, never read.
    public nonisolated enum EnvSource: Equatable, Sendable {
        case plain(String)
        case keychain(String)
        case login(String)
    }

    public nonisolated struct Env: Equatable, Sendable {
        public var key: String
        public var source: EnvSource
    }

    public var id: String
    public var folder: String
    /// The profile file.
    public var path: String
    public var argv: [String]
    /// What the command resolves to now; nil when it is not found.
    public var program: String?
    public var env: [Env]
    /// Files inside the folder whose bytes are part of ``sha256``.
    public var checkedFiles: [String]
    /// The daemon's warnings (a launcher that downloads code, a key that changes loaded code).
    public var warnings: [String]
    public var sha256: String

    public init(id: String, folder: String, path: String, argv: [String], program: String?, env: [Env],
                checkedFiles: [String], warnings: [String], sha256: String) {
        self.id = id
        self.folder = folder
        self.path = path
        self.argv = argv
        self.program = program
        self.env = env
        self.checkedFiles = checkedFiles
        self.warnings = warnings
        self.sha256 = sha256
    }

    /// The prompt in a `_acpmux/harness_enable` result (`{prompt: {...}}`); nil when a field the
    /// sheet needs is missing (no sha256, no command), so nothing is confirmed blind.
    public init?(result: [String: Any]) {
        guard let prompt = result["prompt"] as? [String: Any],
              let id = prompt["id"] as? String, !id.isEmpty,
              let folder = prompt["folder"] as? String, !folder.isEmpty,
              let path = prompt["path"] as? String,
              let argv = prompt["argv"] as? [String], !argv.isEmpty,
              let sha256 = prompt["sha256"] as? String, !sha256.isEmpty else { return nil }
        var env: [Env] = []
        for case let entry as [String: Any] in prompt["env"] as? [Any] ?? [] {
            guard let key = entry["key"] as? String else { return nil }
            switch entry["source"] as? String {
            case "plain": env.append(Env(key: key, source: .plain(entry["value"] as? String ?? "")))
            case "keychain": env.append(Env(key: key, source: .keychain(entry["item"] as? String ?? "")))
            case "env": env.append(Env(key: key, source: .login(entry["variable"] as? String ?? "")))
            // A source the sheet cannot name is not shown as something else.
            default: return nil
            }
        }
        self.init(id: id, folder: folder, path: path, argv: argv, program: prompt["program"] as? String, env: env,
                  checkedFiles: prompt["checkedFiles"] as? [String] ?? [], warnings: prompt["warnings"] as? [String] ?? [],
                  sha256: sha256)
    }

    /// The command line as a shell would read it (each word quoted when it needs it).
    public var commandLine: String {
        argv.map { word in
            let plain = !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "-_./:=@%+,${}".unicodeScalars.contains(scalar)
            }
            return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// `text` with every control and bidi-control character written out (`\n`, `\u{202e}`), so a
    /// profile cannot hide or reorder text on the sheet (the daemon does the same in its CLI text).
    public static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let bidi = (0x200E...0x200F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
                    || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0x061C
                if scalar.properties.generalCategory == .control || bidi {
                    out += String(format: "\\u{%04x}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
