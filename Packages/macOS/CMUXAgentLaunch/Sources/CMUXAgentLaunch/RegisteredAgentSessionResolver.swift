public import Foundation
import CmuxFoundation

/// Which on-disk layout a registered agent uses to identify its sessions.
///
/// A package-owned mirror of the app's `CmuxVaultAgentSessionIDSource`, decoupling
/// the pure session-resolution math below from the app's `CmuxVaultAgentRegistration`
/// Codable struct. The app forwarder maps its registration's source onto this kind
/// when calling ``RegisteredAgentSessionResolver``.
public enum RegisteredAgentSessionIDKind: Sendable, Hashable {
    /// The session id is parsed from a transcript field inside a `.jsonl` rollout.
    case argvOption
    /// A `pi`-compatible per-project `.jsonl` layout (`PiSessionResolver`).
    case piSessionFile
    /// A Grok per-session-directory `chat_history.jsonl` layout (`GrokSessionResolver`).
    case grokSessionDirectory
}

/// The transcript fields a single registered-agent `.jsonl` rollout yields:
/// title, working directory, git branch, and native session id (any of which may
/// be absent depending on the agent's record shape).
///
/// Package-owned value type so the resolver below never constructs an app-side
/// `SessionEntry`; the app loader maps these fields onto a `SessionEntry`.
public struct RegisteredAgentJSONLMetadata: Sendable, Hashable {
    public var title: String
    public var cwd: String?
    public var branch: String?
    public var sessionId: String?

    public init(
        title: String = "",
        cwd: String? = nil,
        branch: String? = nil,
        sessionId: String? = nil
    ) {
        self.title = title
        self.cwd = cwd
        self.branch = branch
        self.sessionId = sessionId
    }
}

/// Resolves the pure, registration-decoupled pieces of a generic registered
/// agent's on-disk session layout: the session roots to scan, the candidate
/// `.jsonl`/`chat_history.jsonl` files under a root, and the transcript metadata
/// inside one file.
///
/// A registered agent (any agent declared in the vault that is not a built-in with
/// its own resolver) stores sessions either as one JSONL file per conversation
/// (`argvOption`) under a configured directory, in a `pi`-compatible per-project
/// layout (`piSessionFile`), or in a Grok per-session-directory layout
/// (`grokSessionDirectory`). This type owns only the path/file/parse math that
/// needs nothing but those primitives plus a `RipgrepFileScanner`; the
/// registration- and `SessionEntry`-coupled assembly stays app-side and forwards
/// the pure pieces here.
///
/// Mirrors `GrokSessionResolver`/`PiSessionResolver`: instance methods over a
/// constructor-injected `RipgrepFileScanner` and `searchMaxFiles` cap so tests can
/// point resolution at a temporary tree and a fake scanner.
public struct RegisteredAgentSessionResolver: Sendable {
    private let ripgrepScanner: RipgrepFileScanner
    private let searchMaxFiles: Int

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - ripgrepScanner: Scans `.jsonl` rollouts (line iteration + needle
    ///     prefiltering); injected so tests can supply a fake.
    ///   - searchMaxFiles: The upper bound on files the metadata scan visits,
    ///     matching the app-side session-index cap.
    public init(ripgrepScanner: RipgrepFileScanner, searchMaxFiles: Int) {
        self.ripgrepScanner = ripgrepScanner
        self.searchMaxFiles = searchMaxFiles
    }

    /// The session roots to scan for a registered agent, given the layout kind and
    /// the configured session directory.
    ///
    /// For `grokSessionDirectory`, delegates to `GrokSessionResolver` and returns
    /// each Grok root's `sessionsRoot`. For `piSessionFile` with a `cwdFilter`, the
    /// configured directory scoped to the `pi` per-project subdirectory derived from
    /// the filter (when one exists). Otherwise the tilde-expanded configured
    /// directory, or `[]` when no directory is configured.
    public func registeredSessionRoots(
        kind: RegisteredAgentSessionIDKind,
        sessionDirectory: String?,
        cwdFilter: String?
    ) -> [String] {
        if case .grokSessionDirectory = kind {
            return GrokSessionResolver()
                .sessionRoots(sessionDirectory: sessionDirectory, cwdFilter: cwdFilter)
                .map(\.sessionsRoot)
        }
        guard let root = sessionDirectory.map({ ($0 as NSString).expandingTildeInPath }) else {
            return []
        }
        if case .piSessionFile = kind,
           let cwdFilter,
           let projectDirectory = PiSessionResolver().projectDirectoryName(for: cwdFilter) {
            return [(root as NSString).appendingPathComponent(projectDirectory)]
        }
        return [root]
    }

    /// The `GROK_HOME`-prefixed resume command for a Grok-backed registered agent,
    /// or `nil` when the command must stay unchanged.
    ///
    /// Returns `nil` (caller keeps the original command) when `grokHome` is
    /// empty/whitespace or the command already references `GROK_HOME`. Otherwise
    /// prepends `env GROK_HOME=<shell-quoted home> ` so a resumed session restarts
    /// in the same Grok home it was launched in.
    public func grokHomePrefixedResumeCommand(
        _ resumeCommand: String,
        grokHome: String?
    ) -> String? {
        guard let grokHome = grokHome?.trimmingCharacters(in: .whitespacesAndNewlines),
              !grokHome.isEmpty,
              !resumeCommand.contains("GROK_HOME") else {
            return nil
        }
        return "env GROK_HOME=\(grokHome.shellQuoted) \(resumeCommand)"
    }

    /// The `chat_history.jsonl` candidate files (with content-modification dates)
    /// directly enumerable under a Grok session root, skipping hidden files.
    ///
    /// Returns `[]` when the root is missing or not a directory.
    public func enumerateGrokHistoryCandidates(
        root: GrokSessionRoot,
        fileManager: FileManager
    ) -> [(URL, Date)] {
        let fm = fileManager
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.sessionsRoot, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fm.enumerator(
                  at: URL(fileURLWithPath: root.sessionsRoot, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "chat_history.jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            candidates.append((url, modified))
        }
        return candidates
    }

    /// The `.jsonl` candidate files (with content-modification dates) directly
    /// enumerable under a registered-agent session root, skipping hidden files.
    ///
    /// Returns `[]` when the root is missing or not a directory.
    public func enumerateRegisteredJSONLCandidates(root: String) -> [(URL, Date)] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fm.enumerator(
                  at: URL(fileURLWithPath: root, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            candidates.append((url, modified))
        }
        return candidates
    }

    /// Extracts session metadata (title, cwd, branch, native session id) from one
    /// registered-agent `.jsonl` rollout, reading at most 512 KB from the head.
    ///
    /// Stops at the first record that supplies every field the layout needs
    /// (`needsNativeSessionID` is true only for `argvOption`). For `piSessionFile`
    /// with no cwd found, falls back to `fallbackCWD` or the cwd inferred from the
    /// file path.
    public func extractRegisteredJSONLMetadata(
        url: URL,
        kind: RegisteredAgentSessionIDKind,
        fallbackCWD: String?
    ) -> RegisteredAgentJSONLMetadata {
        var metadata = RegisteredAgentJSONLMetadata()
        let needsNativeSessionID: Bool
        switch kind {
        case .argvOption:
            needsNativeSessionID = true
        case .piSessionFile, .grokSessionDirectory:
            needsNativeSessionID = false
        }
        let fieldParser = AgentSessionFieldParser()
        let historyParser = AgentHistoryRecordParser(fieldParser: fieldParser)
        ripgrepScanner.forEachJSONLine(url: url, maxBytes: 512 * 1024) { object in
            if metadata.sessionId == nil {
                metadata.sessionId = fieldParser.firstString(in: object, keys: historyParser.registeredJSONLSessionIDKeys())
            }
            if metadata.cwd == nil {
                metadata.cwd = fieldParser.firstString(in: object, keys: historyParser.registeredJSONLCWDKeys())
            }
            if metadata.branch == nil, let git = object["git"] as? [String: Any] {
                metadata.branch = fieldParser.firstString(in: git, keys: ["branch", "gitBranch"])
            }
            if metadata.branch == nil {
                metadata.branch = fieldParser.firstString(in: object, keys: ["gitBranch", "branch"])
            }
            if metadata.title.isEmpty {
                metadata.title = fieldParser.firstTopLevelTitle(in: object) ?? ""
            }
            if metadata.title.isEmpty, let message = object["message"] as? [String: Any] {
                if fieldParser.shouldUseMessageAsTitle(message) {
                    metadata.title = fieldParser.firstText(in: message, keys: ["content", "text"]) ?? ""
                }
            }
            if metadata.title.isEmpty, let messages = object["messages"] as? [[String: Any]] {
                metadata.title = messages.compactMap { message in
                    fieldParser.shouldUseMessageAsTitle(message)
                        ? fieldParser.firstText(in: message, keys: ["content", "text"])
                        : nil
                }.first ?? ""
            }
            return !metadata.title.isEmpty
                && metadata.cwd != nil
                && metadata.branch != nil
                && (!needsNativeSessionID || metadata.sessionId != nil)
        }
        if case .piSessionFile = kind, metadata.cwd == nil {
            metadata.cwd = fallbackCWD ?? historyParser.piCWDInferred(from: url)
        }
        return metadata
    }
}
