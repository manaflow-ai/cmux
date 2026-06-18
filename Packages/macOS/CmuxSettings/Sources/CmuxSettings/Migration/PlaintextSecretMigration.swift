public import Foundation

/// One-time migration that moves a plaintext secret out of the shared
/// `cmux.json` config file and into a secure secret sink, then removes the
/// plaintext from `cmux.json`.
///
/// The socket-control password used to be storable as a plaintext string in
/// `cmux.json` (an editable, copyable, versionable file). Convergence makes the
/// secure ``SecretFileStore`` file the single source of truth, so any lingering
/// plaintext copy must be lifted into the secret sink and then scrubbed from the
/// config.
///
/// The migration is **pure and synchronous** by design: the host runs it at the
/// very start of launch, before any managed-config layer reads `cmux.json`, so
/// scrubbing the key can never race a config reload that would otherwise treat
/// the now-missing key as a removed managed override. All side-effecting
/// dependencies (the secret sink, the timestamp, the file system) are injected,
/// so the behavior is fully unit-testable without touching the real config,
/// keychain, or Application Support.
///
/// ```swift
/// let store = SocketControlPasswordStore()
/// PlaintextSecretMigration.scrub(
///     plaintextKeyPath: ["automation", "socketPassword"],
///     configURL: configFileURL,
///     loadCurrentSecret: { (try? store.loadPassword()) ?? nil },
///     saveSecret: { try store.savePassword($0) },
///     backupTimestamp: timestamp
/// )
/// ```
public enum PlaintextSecretMigration {
    /// The result of a migration attempt, surfaced for logging and tests.
    public enum Outcome: Equatable, Sendable {
        /// `cmux.json` does not exist or could not be read; nothing to do.
        case noConfigFile
        /// The file parsed but does not contain the plaintext key; nothing to do.
        case noPlaintextKey
        /// The file could not be parsed (even after tolerating JSONC). Left
        /// completely intact so a malformed/unsupported config is never
        /// corrupted; the plaintext (if any) is not migrated.
        case parseFailedLeftIntact
        /// Copying the plaintext into the secret sink failed, so `cmux.json` was
        /// left completely intact (not scrubbed). The plaintext is preserved so a
        /// later run can retry rather than losing the only copy of the secret.
        case saveFailedLeftIntact
        /// A plaintext value was copied into the empty secret sink and then
        /// removed from `cmux.json`.
        case migratedAndScrubbed
        /// The key was present but the secret sink already held a value (so the
        /// plaintext was not copied, to avoid clobbering), and the plaintext was
        /// removed from `cmux.json`. Also covers an empty/whitespace plaintext.
        case scrubbedWithoutCopy
    }

    /// Lifts a plaintext secret at `plaintextKeyPath` out of `cmux.json` into the
    /// secret sink (only when the sink is empty), then removes the key from
    /// `cmux.json` after backing the file up.
    ///
    /// Idempotent: once the key is gone, later runs return ``Outcome/noPlaintextKey``.
    /// Never overwrites an existing secret. Never corrupts an unparseable file.
    ///
    /// - Parameters:
    ///   - plaintextKeyPath: The nested object path to the plaintext value, e.g.
    ///     `["automation", "socketPassword"]`.
    ///   - configURL: The `cmux.json` location.
    ///   - loadCurrentSecret: Returns the current secret-sink value, or `nil`/empty when unset.
    ///   - saveSecret: Persists a value into the secret sink. If it throws, the
    ///     plaintext is left in `cmux.json` (``Outcome/saveFailedLeftIntact``) so
    ///     the only copy of the secret is never lost to a failed write.
    ///   - backupTimestamp: A filename-safe timestamp used for the `.bak` copy
    ///     (injected so the result is deterministic in tests).
    ///   - fileManager: File system access (injected for tests).
    /// - Returns: The ``Outcome``.
    @discardableResult
    public static func scrub(
        plaintextKeyPath: [String],
        configURL: URL,
        loadCurrentSecret: () -> String?,
        saveSecret: (String) throws -> Void,
        backupTimestamp: String,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard !plaintextKeyPath.isEmpty else { return .noPlaintextKey }
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL) else {
            return .noConfigFile
        }
        guard let root = parseObject(data) else {
            return .parseFailedLeftIntact
        }
        guard let leaf = lookup(plaintextKeyPath, in: root) else {
            return .noPlaintextKey
        }

        let plaintext = (leaf as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var outcome: Outcome = .scrubbedWithoutCopy
        if let plaintext, !plaintext.isEmpty {
            let existing = loadCurrentSecret()?.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing == nil || existing?.isEmpty == true {
                do {
                    try saveSecret(plaintext)
                } catch {
                    // The secure write failed; leave the plaintext in cmux.json so a
                    // later run can retry rather than losing the only copy.
                    return .saveFailedLeftIntact
                }
                outcome = .migratedAndScrubbed
            }
        }

        backUp(configURL: configURL, timestamp: backupTimestamp, fileManager: fileManager)

        var newRoot = root
        removeAndPrune(plaintextKeyPath, in: &newRoot)
        if let rewritten = try? JSONSerialization.data(
            withJSONObject: newRoot,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? rewritten.write(to: configURL, options: .atomic)
        }
        return outcome
    }

    // MARK: - Parsing

    private static func parseObject(_ data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let stripped = stripJSONC(text)
        guard let strippedData = stripped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Removes `//` line comments, `/* */` block comments, and trailing commas
    /// that appear outside of string literals, so a JSONC `cmux.json` can be
    /// parsed by `JSONSerialization`. String contents (including any `//` or
    /// commas inside them) are preserved verbatim.
    private static func stripJSONC(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                i += 2
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
            out.append(c)
            i += 1
        }
        return stripTrailingCommas(out)
    }

    /// Removes trailing commas (a comma whose next non-whitespace character is
    /// `}` or `]`) from already comment-stripped JSONC text, while preserving
    /// commas that appear inside string literals.
    ///
    /// A global regex over the whole text would rewrite a `,` followed by a brace
    /// inside a string value (for example `"a, }"`); this pass tracks string state
    /// so only structural trailing commas are dropped.
    private static func stripTrailingCommas(_ chars: [Character]) -> String {
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    // Structural trailing comma: drop it, keep the whitespace/bracket.
                    i += 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    // MARK: - Nested object navigation

    private static func lookup(_ path: [String], in root: [String: Any]) -> Any? {
        var node: Any = root
        for component in path {
            guard let dict = node as? [String: Any], let next = dict[component] else {
                return nil
            }
            node = next
        }
        return node
    }

    /// Removes the value at `path`, then prunes any parent objects that became
    /// empty as a result.
    private static func removeAndPrune(_ path: [String], in root: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            root.removeValue(forKey: first)
            return
        }
        guard var child = root[first] as? [String: Any] else { return }
        removeAndPrune(Array(path.dropFirst()), in: &child)
        if child.isEmpty {
            root.removeValue(forKey: first)
        } else {
            root[first] = child
        }
    }

    // MARK: - Backup

    private static func backUp(configURL: URL, timestamp: String, fileManager: FileManager) {
        let backupURL = configURL.deletingPathExtension()
            .appendingPathExtension("\(timestamp).bak")
        try? fileManager.copyItem(at: configURL, to: backupURL)
    }
}
