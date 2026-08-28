/// Installs and removes cmux's Codex hooks in a `config.toml` body.
///
/// The editor is deliberately a pure value type: callers provide the existing
/// text and receive the rewritten text, so package tests can exercise the exact
/// install and uninstall pipeline without launching the app or touching a user's
/// filesystem. It preserves the config's line-ending style and treats only the
/// blocks marked as cmux-owned as removable.
public struct CmuxCodexConfigEditor: Sendable {
    /// One Codex hook trust table that cmux owns.
    public struct HookTrustEntry: Equatable, Sendable {
        /// The stable, unescaped TOML key for the hook table.
        public let key: String
        /// The hash Codex uses to approve the hook command.
        public let trustedHash: String

        /// Creates a hook trust entry.
        ///
        /// - Parameters:
        ///   - key: The stable, unescaped TOML key for the hook table.
        ///   - trustedHash: The hash Codex uses to approve the hook command.
        public init(key: String, trustedHash: String) {
            self.key = key
            self.trustedHash = trustedHash
        }
    }

    /// The result of installing Codex hooks into a config body.
    public struct HookInstallResult: Equatable, Sendable {
        /// The rewritten config body.
        public let content: String
        /// Whether a non-empty trust block was installed.
        public let installedTrust: Bool

        /// Creates an install result.
        ///
        /// - Parameters:
        ///   - content: The rewritten config body.
        ///   - installedTrust: Whether a non-empty trust block was installed.
        public init(content: String, installedTrust: Bool) {
            self.content = content
            self.installedTrust = installedTrust
        }
    }

    /// Creates an editor with no filesystem or process dependencies.
    public init() {}

    /// Builds a process-local Codex config override that disables the supplied hooks.
    ///
    /// - Parameter entries: Hook trust entries whose keys should be disabled.
    /// - Returns: A stable TOML override, or `nil` when no entries are supplied.
    public func hookStateOverrideDisabling(_ entries: [HookTrustEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let state = entries.sorted { $0.key < $1.key }.map { entry in
            "\"\(tomlBasicStringContent(entry.key))\"={enabled=false}"
        }.joined(separator: ",")
        return "hooks.state={\(state)}"
    }

    /// Installs the hooks feature and the supplied cmux-owned trust tables.
    ///
    /// Existing cmux blocks and matching trust tables are removed before the
    /// replacements are written. This makes reinstall idempotent while leaving
    /// unrelated user-owned TOML untouched.
    ///
    /// - Parameters:
    ///   - existingContent: The current `config.toml` body.
    ///   - trustEntries: The cmux-owned hook trust tables to install.
    ///   - removingKeyPrefixes: Raw key prefixes whose stale trust tables may be
    ///     removed during reinstall. The editor applies TOML basic-string
    ///     escaping before matching them.
    ///   - removingTrustedHashes: Additional stale hashes whose trust tables may
    ///     be removed during reinstall.
    /// - Returns: The rewritten content and whether trust was installed.
    public func installingHooks(
        in existingContent: String,
        trustEntries: [HookTrustEntry],
        removingKeyPrefixes: Set<String> = [],
        removingTrustedHashes: Set<String> = []
    ) -> HookInstallResult {
        let removingEscapedKeyPrefixes = Set(removingKeyPrefixes.map { tomlBasicStringContent($0) })
        let trustClean = removingHookTrust(
            in: existingContent,
            entries: trustEntries,
            removingEscapedKeyPrefixes: removingEscapedKeyPrefixes,
            removingTrustedHashes: removingTrustedHashes
        )
        let featureContent = installingHooksFeature(in: trustClean)
        return installingHookTrust(
            in: featureContent,
            entries: trustEntries,
            removingEscapedKeyPrefixes: removingEscapedKeyPrefixes,
            removingTrustedHashes: removingTrustedHashes
        )
    }

    /// Removes cmux's hooks feature, trust block, and matching trust tables.
    ///
    /// User-owned feature settings, trust tables, and surrounding TOML remain
    /// in place. The returned text uses the same line-ending style as the input.
    ///
    /// - Parameters:
    ///   - existingContent: The current `config.toml` body.
    ///   - entries: The cmux-owned hook trust tables to remove.
    ///   - removingKeyPrefixes: Raw key prefixes that identify stale cmux trust
    ///     tables. The editor applies TOML basic-string escaping before matching.
    ///   - removingTrustedHashes: Additional stale hashes whose trust tables may
    ///     be removed.
    /// - Returns: The config body with cmux-owned hooks removed.
    public func uninstallingHooks(
        from existingContent: String,
        removingHookTrustEntries entries: [HookTrustEntry] = [],
        removingKeyPrefixes: Set<String> = [],
        removingTrustedHashes: Set<String> = []
    ) -> String {
        let lineEnding = CmuxConfigLines().lineEnding(of: existingContent)
        var lines = tomlLines(from: existingContent)
        let escapedKeys = Set(entries.map { tomlBasicStringContent($0.key) })
        let trustedHashes = Set(entries.map(\.trustedHash)).union(removingTrustedHashes)
        let removingEscapedKeyPrefixes = Set(removingKeyPrefixes.map { tomlBasicStringContent($0) })
        removeCmuxCodexHooksFeatureBlock(from: &lines)
        if removeCmuxCodexHookTrustBlock(
            from: &lines,
            removingEscapedKeys: escapedKeys,
            removingEscapedKeyPrefixes: removingEscapedKeyPrefixes,
            removingTrustedHashes: trustedHashes
        ) == .malformed {
            stripMalformedCmuxCodexHookTrustMarker(from: &lines)
        }
        removeCodexHookTrustTables(withEscapedKeys: escapedKeys, from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }
        lines.removeAll { tomlLineDefinesDottedFeaturesKey("codex_hooks", line: $0) }
        removeEmptyFeaturesTable(from: &lines)
        return tomlContent(from: lines, lineEnding: lineEnding)
    }
}
