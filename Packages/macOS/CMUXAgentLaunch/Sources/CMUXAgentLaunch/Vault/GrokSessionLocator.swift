import Foundation

/// Resolves the on-disk locations of Grok agent sessions for a registered
/// agent, given a home directory and process environment.
///
/// The locator is configured by the `homeDirectory` and `environment` it should
/// resolve against (injected for testability; defaulting to the live process
/// values). Session-directory and hook-store inputs that originate in the app
/// (`CmuxVaultAgentRegistration.sessionDirectory`, the Grok hook-store file URL)
/// are passed in per call so this type carries no dependency on app-side
/// registration types. Stateless path helpers are exposed as `static` members.
public struct GrokSessionLocator: Sendable {
    /// Home directory used to expand `~` paths and locate the default root.
    public let homeDirectory: String
    /// Process environment consulted for `GROK_HOME`.
    public let environment: [String: String]

    /// Creates a locator bound to a home directory and environment.
    public init(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// Percent-encodes a working directory the way Grok names its per-project
    /// session subdirectories (unreserved RFC 3986 bytes pass through; all
    /// others become `%XX`).
    public static func encodedSessionCWD(_ cwd: String) -> String {
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

    /// Decodes a Grok per-project directory name back into the working
    /// directory it represents, standardized.
    public static func workingDirectory(fromProjectDirectoryName name: String) -> String? {
        let decoded = name.removingPercentEncoding ?? name
        return normalizedWorkingDirectory(decoded)
    }

    /// Trims and standardizes a working-directory path, returning `nil` for
    /// empty input.
    public static func normalizedWorkingDirectory(_ value: String?) -> String? {
        let trimmed = normalized(value)
        return trimmed.map { ($0 as NSString).standardizingPath }
    }

    /// All distinct encoded forms of a working directory (raw and standardized).
    private static func encodedSessionCWDs(for cwd: String) -> [String] {
        guard let rawCwd = normalized(cwd) else {
            return []
        }
        var seen = Set<String>()
        return [rawCwd, (rawCwd as NSString).standardizingPath]
            .map(encodedSessionCWD)
            .filter { seen.insert($0).inserted }
    }

    /// All Grok sessions roots to scan for the given registration session
    /// directory and optional working-directory filter, including roots derived
    /// from observed `GROK_HOME` values when the registration uses the default
    /// root.
    public func sessionRoots(
        sessionDirectory: String?,
        cwdFilter: String?,
        observedGrokHomes: [String] = []
    ) -> [GrokSessionRoot] {
        let root = sessionRoot(sessionDirectory: sessionDirectory)
        var roots = [root]
        if registrationUsesDefaultGrokRoot(sessionDirectory: sessionDirectory) {
            for grokHome in observedGrokHomes {
                guard let candidate = sessionRoot(grokHome: grokHome) else {
                    continue
                }
                roots.append(candidate)
            }
            roots = Self.deduplicatedSessionRoots(roots)
        }
        guard let cwdFilter = Self.normalized(cwdFilter) else {
            return roots
        }
        let scopedRoots = roots.flatMap { root in
            Self.encodedSessionCWDs(for: cwdFilter).map { encodedCwd in
                let scopedRoot = (root.sessionsRoot as NSString).appendingPathComponent(encodedCwd)
                return GrokSessionRoot(sessionsRoot: scopedRoot, grokHomeForResume: root.grokHomeForResume)
            }
        }
        return Self.deduplicatedSessionRoots(scopedRoots)
    }

    /// Distinct `GROK_HOME` values recovered from the Grok hook store file at
    /// `hookStoreFileURL`, expanded against this locator's home directory.
    public func observedGrokHomes(
        hookStoreFileURL: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        guard fileManager.fileExists(atPath: hookStoreFileURL.path),
              let data = try? Data(contentsOf: hookStoreFileURL),
              let state = try? JSONDecoder().decode(GrokHookObservedSessionStoreFile.self, from: data) else {
            return []
        }

        var seen = Set<String>()
        var homes: [String] = []
        for record in state.sessions.values {
            guard let rawHome = Self.normalized(record.launchCommand?.environment?["GROK_HOME"]) else {
                continue
            }
            let home = expandTilde(rawHome)
            guard seen.insert(home).inserted else { continue }
            homes.append(home)
        }
        return homes
    }

    private func defaultSessionsRoot() -> String {
        let standardizedHome = expandTilde(homeDirectory)
        return ((standardizedHome as NSString).appendingPathComponent(".grok") as NSString)
            .appendingPathComponent("sessions")
    }

    private func sessionRoot(sessionDirectory: String?) -> GrokSessionRoot {
        let rawRoot: String
        let configuredRoot = Self.normalized(sessionDirectory)
        let configuredIsDefault = configuredRoot.map {
            expandTilde($0)
                == (defaultSessionsRoot() as NSString).standardizingPath
        } ?? false
        if let grokHome = Self.normalized(environment["GROK_HOME"]),
           configuredRoot == nil || configuredIsDefault {
            rawRoot = (grokHome as NSString).appendingPathComponent("sessions")
        } else if let configured = configuredRoot {
            rawRoot = configured
        } else {
            rawRoot = defaultSessionsRoot()
        }
        let sessionsRoot = expandTilde(rawRoot)
        let grokHome = Self.grokHomeForResume(
            sessionsRoot: sessionsRoot,
            defaultSessionsRoot: defaultSessionsRoot()
        )
        return GrokSessionRoot(sessionsRoot: sessionsRoot, grokHomeForResume: grokHome)
    }

    private static func grokHomeForResume(sessionsRoot: String, defaultSessionsRoot: String) -> String? {
        let standardizedRoot = (sessionsRoot as NSString).standardizingPath
        let standardizedDefault = (defaultSessionsRoot as NSString).standardizingPath
        guard standardizedRoot != standardizedDefault else { return nil }
        guard (standardizedRoot as NSString).lastPathComponent == "sessions" else { return nil }
        return (standardizedRoot as NSString).deletingLastPathComponent
    }

    private func sessionRoot(grokHome: String) -> GrokSessionRoot? {
        guard let normalizedHome = Self.normalized(grokHome) else { return nil }
        let expandedHome = expandTilde(normalizedHome)
        let sessionsRoot = (expandedHome as NSString).appendingPathComponent("sessions")
        let grokHome = Self.grokHomeForResume(
            sessionsRoot: sessionsRoot,
            defaultSessionsRoot: defaultSessionsRoot()
        )
        return GrokSessionRoot(sessionsRoot: sessionsRoot, grokHomeForResume: grokHome)
    }

    private func registrationUsesDefaultGrokRoot(sessionDirectory: String?) -> Bool {
        guard let configuredRoot = Self.normalized(sessionDirectory) else {
            return true
        }
        let expandedConfigured = expandTilde(configuredRoot)
        let expandedDefault = (defaultSessionsRoot() as NSString).standardizingPath
        return expandedConfigured == expandedDefault
    }

    private static func deduplicatedSessionRoots(_ roots: [GrokSessionRoot]) -> [GrokSessionRoot] {
        var seen = Set<String>()
        return roots.filter { root in
            seen.insert((root.sessionsRoot as NSString).standardizingPath).inserted
        }
    }

    private func expandTilde(_ path: String) -> String {
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

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
