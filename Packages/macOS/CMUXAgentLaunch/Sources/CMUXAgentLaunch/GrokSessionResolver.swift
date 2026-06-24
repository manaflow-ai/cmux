public import Foundation

/// One Grok sessions root: the directory Grok history files live under, plus the
/// `GROK_HOME` value (if any) needed to reconstruct a resume command that targets
/// that root.
///
/// Grok writes per-conversation `chat_history.jsonl` files under a sessions root
/// (default `~/.grok/sessions`), optionally relocated by a `GROK_HOME` override.
/// When a root is a non-default `<grokHome>/sessions`, ``grokHomeForResume`` carries
/// the `<grokHome>` so the resume command can re-export `GROK_HOME`.
public struct GrokSessionRoot: Sendable, Hashable {
    /// The directory Grok session history files are enumerated under.
    public let sessionsRoot: String

    /// The `GROK_HOME` value to re-export when resuming from this root, or `nil`
    /// when the root is the default and no `GROK_HOME` reconstruction is needed.
    public let grokHomeForResume: String?

    /// Creates a sessions root.
    public init(sessionsRoot: String, grokHomeForResume: String?) {
        self.sessionsRoot = sessionsRoot
        self.grokHomeForResume = grokHomeForResume
    }
}

/// The subset of the Grok hook-state store file this resolver decodes: each
/// session's recorded launch-command environment, from which observed `GROK_HOME`
/// values are harvested.
private struct GrokHookObservedSessionStoreFile: Decodable {
    var sessions: [String: GrokHookObservedSessionRecord]

    private enum CodingKeys: String, CodingKey {
        case sessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(
            [String: GrokHookObservedSessionRecord].self,
            forKey: .sessions
        ) ?? [:]
    }
}

/// One recorded session in the Grok hook-state store, narrowed to its launch command.
private struct GrokHookObservedSessionRecord: Decodable {
    var launchCommand: GrokHookObservedLaunchCommand?
}

/// The launch command recorded for an observed Grok session, narrowed to its
/// environment so `GROK_HOME` can be read back.
private struct GrokHookObservedLaunchCommand: Decodable {
    var environment: [String: String]?
}

/// Resolves the pure, process-independent pieces of a Grok-compatible agent's
/// on-disk session layout: the default sessions root, the per-`cwd` directory-name
/// encoding Grok uses, the sessions roots to scan for a registration, and the set
/// of `GROK_HOME` values observed in the hook-state store.
///
/// Grok writes one `chat_history.jsonl` per conversation under a sessions root
/// (default `~/.grok/sessions`), nested in a per-`cwd` subdirectory whose name is
/// the working directory percent-encoded with an unreserved-byte allowlist. A
/// `GROK_HOME` environment override (configured, ambient, or observed in the hook
/// store) relocates the root to `<grokHome>/sessions`. This type owns only the
/// path/encoding math plus the hook-store decode; the registration value it needs
/// is the configured session directory string, passed in so the package never
/// imports the app's registration type, and the hook-store file URL is resolved
/// app-side and passed in so the package never imports the app's agent-kind enum.
///
/// Mirrors ``PiSessionResolver``: instance methods over a constructor-injected
/// `FileManager` so tests can point resolution at a temporary tree.
public struct GrokSessionResolver {
    private let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameter fileManager: Injected so tests can point resolution at a
    ///   temporary sessions tree; defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The default sessions root Grok writes under: `<homeDirectory>/.grok/sessions`,
    /// with `homeDirectory` tilde-expanded first.
    ///
    /// - Parameter homeDirectory: The home directory to root under; defaults to
    ///   `NSHomeDirectory()`.
    public func defaultSessionsRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        let standardizedHome = expandTilde(homeDirectory, homeDirectory: homeDirectory)
        return ((standardizedHome as NSString).appendingPathComponent(".grok") as NSString)
            .appendingPathComponent("sessions")
    }

    /// Percent-encodes a working directory into Grok's per-`cwd` subdirectory name,
    /// preserving the unreserved-byte allowlist (`A-Z a-z 0-9 - . _ ~`) literally
    /// and `%XX`-encoding every other byte.
    ///
    /// - Parameter cwd: The working directory to encode.
    public func encodedSessionCWD(_ cwd: String) -> String {
        var encoded = ""
        for byte in cwd.utf8 {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x7E
            if isUnreserved {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    /// The working directory a per-project directory name decodes back to:
    /// percent-decoded then standardized, or `nil` when it standardizes away.
    ///
    /// - Parameter name: The per-project subdirectory name.
    public func workingDirectory(fromProjectDirectoryName name: String) -> String? {
        let decoded = name.removingPercentEncoding ?? name
        return normalizedWorkingDirectory(decoded)
    }

    /// A working directory normalized for comparison: trimmed, emptied to `nil`,
    /// then path-standardized.
    ///
    /// - Parameter value: The working directory to normalize.
    public func normalizedWorkingDirectory(_ value: String?) -> String? {
        let trimmed = normalized(value)
        return trimmed.map { ($0 as NSString).standardizingPath }
    }

    /// The distinct percent-encoded subdirectory names a single working directory
    /// can map to: the raw form and the path-standardized form, de-duplicated.
    ///
    /// - Parameter cwd: The working directory to encode.
    public func encodedSessionCWDs(for cwd: String) -> [String] {
        guard let rawCwd = normalized(cwd) else {
            return []
        }
        var seen = Set<String>()
        return [rawCwd, (rawCwd as NSString).standardizingPath]
            .map(encodedSessionCWD)
            .filter { seen.insert($0).inserted }
    }

    /// The single sessions root a registration's configured session directory
    /// resolves to, accounting for a `GROK_HOME` environment override.
    ///
    /// - Parameters:
    ///   - sessionDirectory: The registration's configured session directory
    ///     (`registration.sessionDirectory`), passed in so the package does not
    ///     import the app registration type.
    ///   - environment: The process environment to read `GROK_HOME` from.
    ///   - homeDirectory: The home directory for tilde expansion and the default root.
    public func sessionRoot(
        sessionDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> GrokSessionRoot {
        let rawRoot: String
        let configuredRoot = normalized(sessionDirectory)
        let configuredIsDefault = configuredRoot.map {
            expandTilde($0, homeDirectory: homeDirectory)
                == (defaultSessionsRoot(homeDirectory: homeDirectory) as NSString).standardizingPath
        } ?? false
        if let grokHome = normalized(environment["GROK_HOME"]),
           configuredRoot == nil || configuredIsDefault {
            rawRoot = (grokHome as NSString).appendingPathComponent("sessions")
        } else if let configured = configuredRoot {
            rawRoot = configured
        } else {
            rawRoot = defaultSessionsRoot(homeDirectory: homeDirectory)
        }
        let sessionsRoot = expandTilde(rawRoot, homeDirectory: homeDirectory)
        let grokHome = grokHomeForResume(
            sessionsRoot: sessionsRoot,
            defaultSessionsRoot: defaultSessionsRoot(homeDirectory: homeDirectory)
        )
        return GrokSessionRoot(sessionsRoot: sessionsRoot, grokHomeForResume: grokHome)
    }

    /// Every sessions root to scan for a registration: the configured root plus,
    /// when the registration uses the default Grok root, one root per observed
    /// `GROK_HOME`, optionally scoped to a working directory's encoded subdirectories.
    ///
    /// - Parameters:
    ///   - sessionDirectory: The registration's configured session directory.
    ///   - cwdFilter: When non-nil, scopes each root to that working directory's
    ///     encoded subdirectory names.
    ///   - environment: The process environment to read `GROK_HOME` from.
    ///   - homeDirectory: The home directory for tilde expansion and the default root.
    ///   - observedGrokHomes: `GROK_HOME` values harvested from the hook store via
    ///     ``observedGrokHomes(hookStoreFileURL:homeDirectory:)``.
    public func sessionRoots(
        sessionDirectory: String?,
        cwdFilter: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        observedGrokHomes: [String] = []
    ) -> [GrokSessionRoot] {
        let root = sessionRoot(
            sessionDirectory: sessionDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )
        var roots = [root]
        if registrationUsesDefaultGrokRoot(sessionDirectory: sessionDirectory, homeDirectory: homeDirectory) {
            for grokHome in observedGrokHomes {
                guard let candidate = sessionRoot(
                    grokHome: grokHome,
                    homeDirectory: homeDirectory
                ) else {
                    continue
                }
                roots.append(candidate)
            }
            roots = deduplicatedSessionRoots(roots)
        }
        guard let cwdFilter = normalized(cwdFilter) else {
            return roots
        }
        let scopedRoots = roots.flatMap { root in
            encodedSessionCWDs(for: cwdFilter).map { encodedCwd in
                let scopedRoot = (root.sessionsRoot as NSString).appendingPathComponent(encodedCwd)
                return GrokSessionRoot(sessionsRoot: scopedRoot, grokHomeForResume: root.grokHomeForResume)
            }
        }
        return deduplicatedSessionRoots(scopedRoots)
    }

    /// The distinct `GROK_HOME` values recorded in the Grok hook-state store, each
    /// tilde-expanded.
    ///
    /// - Parameters:
    ///   - hookStoreFileURL: The hook-state store file URL, resolved app-side from
    ///     the agent-kind enum and passed in so the package does not import it.
    ///   - homeDirectory: The home directory for tilde expansion.
    public func observedGrokHomes(
        hookStoreFileURL: URL,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        guard fileManager.fileExists(atPath: hookStoreFileURL.path),
              let data = try? Data(contentsOf: hookStoreFileURL),
              let state = try? JSONDecoder().decode(GrokHookObservedSessionStoreFile.self, from: data) else {
            return []
        }

        var seen = Set<String>()
        var homes: [String] = []
        for record in state.sessions.values {
            guard let rawHome = normalized(record.launchCommand?.environment?["GROK_HOME"]) else {
                continue
            }
            let home = expandTilde(rawHome, homeDirectory: homeDirectory)
            guard seen.insert(home).inserted else { continue }
            homes.append(home)
        }
        return homes
    }

    private func grokHomeForResume(sessionsRoot: String, defaultSessionsRoot: String) -> String? {
        let standardizedRoot = (sessionsRoot as NSString).standardizingPath
        let standardizedDefault = (defaultSessionsRoot as NSString).standardizingPath
        guard standardizedRoot != standardizedDefault else { return nil }
        guard (standardizedRoot as NSString).lastPathComponent == "sessions" else { return nil }
        return (standardizedRoot as NSString).deletingLastPathComponent
    }

    private func sessionRoot(grokHome: String, homeDirectory: String) -> GrokSessionRoot? {
        guard let normalizedHome = normalized(grokHome) else { return nil }
        let expandedHome = expandTilde(normalizedHome, homeDirectory: homeDirectory)
        let sessionsRoot = (expandedHome as NSString).appendingPathComponent("sessions")
        let grokHome = grokHomeForResume(
            sessionsRoot: sessionsRoot,
            defaultSessionsRoot: defaultSessionsRoot(homeDirectory: homeDirectory)
        )
        return GrokSessionRoot(sessionsRoot: sessionsRoot, grokHomeForResume: grokHome)
    }

    private func registrationUsesDefaultGrokRoot(
        sessionDirectory: String?,
        homeDirectory: String
    ) -> Bool {
        guard let configuredRoot = normalized(sessionDirectory) else {
            return true
        }
        let expandedConfigured = expandTilde(configuredRoot, homeDirectory: homeDirectory)
        let expandedDefault = (defaultSessionsRoot(homeDirectory: homeDirectory) as NSString).standardizingPath
        return expandedConfigured == expandedDefault
    }

    private func deduplicatedSessionRoots(_ roots: [GrokSessionRoot]) -> [GrokSessionRoot] {
        var seen = Set<String>()
        return roots.filter { root in
            seen.insert((root.sessionsRoot as NSString).standardizingPath).inserted
        }
    }

    private func expandTilde(_ path: String, homeDirectory: String) -> String {
        let home = ((homeDirectory as NSString).expandingTildeInPath as NSString).standardizingPath
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return ((home as NSString).appendingPathComponent(suffix) as NSString).standardizingPath
        }
        return ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
