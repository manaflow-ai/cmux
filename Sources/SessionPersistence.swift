import CMUXAgentLaunch
import CoreGraphics
import CmuxCore
import Foundation
import Bonsplit
import CmuxWorkspaces
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

enum SessionSnapshotSchema {
    static let currentVersion = 1
}

enum SessionPersistencePolicy {
    static let sidebarMinimumWidthKey = "sidebarMinimumWidth"
    // Keep the default equal to the minimum so a fresh sidebar starts at the
    // minimum width. The titlebar title tracks the sidebar's actual width only
    // when it is wider than the minimum, so a default above the minimum would make
    // the folder/title shift when toggling the sidebar at the default width.
    static let defaultSidebarWidth: Double = 216
    static let defaultMinimumSidebarWidth: Double = 216
    static let minimumSidebarWidth: Double = 216
    static let sidebarMinimumWidthRange: ClosedRange<Double> = 120...260
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512

    static func sanitizedSidebarWidth(_ candidate: Double?, defaults: UserDefaults = .standard) -> Double {
        let resolvedMinimum = resolvedMinimumSidebarWidth(defaults: defaults)
        let fallback = min(max(defaultSidebarWidth, resolvedMinimum), maximumSidebarWidth)
        guard let candidate, candidate.isFinite else { return fallback }
        return min(max(candidate, resolvedMinimum), maximumSidebarWidth)
    }

    static func resolvedMinimumSidebarWidth(defaults: UserDefaults = .standard) -> Double {
        guard let candidate = storedSidebarMinimumWidth(defaults: defaults) else {
            return defaultMinimumSidebarWidth
        }
        return sanitizedMinimumSidebarWidth(candidate)
    }

    static func sanitizedMinimumSidebarWidth(_ candidate: Double) -> Double {
        guard candidate.isFinite else { return defaultMinimumSidebarWidth }
        return min(max(candidate, sidebarMinimumWidthRange.lowerBound), sidebarMinimumWidthRange.upperBound)
    }

    private static func storedSidebarMinimumWidth(defaults: UserDefaults) -> Double? {
        if let value = defaults.object(forKey: sidebarMinimumWidthKey) as? NSNumber {
            return value.doubleValue
        }
        if let value = defaults.string(forKey: sidebarMinimumWidthKey) {
            return Double(value)
        }
        return nil
    }
}

// `SessionRestorePolicy` (the launch-time automated-test detection and
// session-restore gating decision over ProcessInfo env + CommandLine args) now
// lives in CmuxWorkspaces (Session/SessionRestorePolicy.swift) as a real value
// type with constructor-injected arguments/environment. It is imported via
// `import CmuxWorkspaces`.

enum SurfaceResumeApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case manual
    case prompt
    case auto
}

nonisolated struct SurfaceResumeBindingSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case name
        case kind
        case command
        case cwd
        case checkpointId
        case source
        case environment
        case autoResume
        case approvalPolicy
        case approvalRecordId
        case updatedAt
    }

    var name: String?
    var kind: String?
    var command: String
    var cwd: String?
    var checkpointId: String?
    var source: String?
    var environment: [String: String]?
    var autoResume: Bool?
    var approvalPolicy: SurfaceResumeApprovalPolicy?
    var approvalRecordId: String?
    var updatedAt: TimeInterval

    init(
        name: String? = nil,
        kind: String? = nil,
        command: String,
        cwd: String? = nil,
        checkpointId: String? = nil,
        source: String? = nil,
        environment: [String: String]? = nil,
        autoResume: Bool? = nil,
        approvalPolicy: SurfaceResumeApprovalPolicy? = nil,
        approvalRecordId: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalizedCwd = Self.normalized(cwd)
        let normalizedSource = Self.normalized(source)
        self.name = Self.normalized(name)
        self.kind = Self.normalized(kind)
        self.command = Self.sanitizedStartupCommand(
            command,
            cwd: normalizedCwd,
            source: normalizedSource
        )
        self.cwd = normalizedCwd
        self.checkpointId = Self.normalized(checkpointId)
        self.source = normalizedSource
        self.environment = Self.normalizedEnvironment(environment)
        self.autoResume = autoResume
        self.approvalPolicy = approvalPolicy
        self.approvalRecordId = Self.normalized(approvalRecordId)
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            kind: try container.decodeIfPresent(String.self, forKey: .kind),
            command: try container.decode(String.self, forKey: .command),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            checkpointId: try container.decodeIfPresent(String.self, forKey: .checkpointId),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            environment: try container.decodeIfPresent([String: String].self, forKey: .environment),
            autoResume: try container.decodeIfPresent(Bool.self, forKey: .autoResume),
            approvalPolicy: try container.decodeIfPresent(SurfaceResumeApprovalPolicy.self, forKey: .approvalPolicy),
            approvalRecordId: try container.decodeIfPresent(String.self, forKey: .approvalRecordId),
            updatedAt: try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt)
                ?? Date().timeIntervalSince1970
        )
    }

    var isProcessDetected: Bool {
        source == "process-detected"
    }

    var isAgentHookBinding: Bool {
        source == "agent-hook"
    }

    var isCLIBinding: Bool {
        source == "cli"
    }

    var allowsAutomaticResume: Bool {
        autoResume == true
    }

    func shouldYieldToDetectedSurfaceResumeBinding(_ detectedBinding: SurfaceResumeBindingSnapshot) -> Bool {
        detectedBinding.isProcessDetected && (isProcessDetected || isAgentHookBinding)
    }

    static let maxInlineStartupInputBytes = SessionRestorableAgentSnapshot.maxInlineStartupInputBytes

    var startupInput: String? {
        inlineStartupInput
    }

    var inlineStartupInput: String? {
        let trimmed = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let environment, !environment.isEmpty else {
            return trimmed + "\n"
        }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }
        let argv = ["/usr/bin/env"] + assignments + ["/bin/zsh", "-lc", trimmed]
        return argv.map(Self.shellSingleQuoted).joined(separator: " ") + "\n"
    }

    private var startupCommand: String {
        Self.sanitizedStartupCommand(command, cwd: cwd, source: source)
    }

    private static func sanitizedStartupCommand(
        _ command: String,
        cwd: String?,
        source: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == "agent-hook" else { return trimmed }
        return TerminalStartupWorkingDirectoryPrefix().replacingRequiredChangeDirectoryPrefix(
            in: trimmed,
            workingDirectory: cwd
        )
    }

    func startupInputWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true
    ) -> String? {
        guard let inlineInput = inlineStartupInput else { return nil }
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard allowLauncherScript else { return inlineInput }
        guard let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
            inlineInput: inlineInput,
            binding: self,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }

    func startupCommandWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        guard let inlineInput = inlineStartupInput,
              let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
                  inlineInput: inlineInput,
                  binding: self,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  returnToLoginShell: true
              ) else {
            return nil
        }
        return "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))"
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func normalizedEnvironment(_ environment: [String: String]?) -> [String: String]? {
        guard let environment else { return nil }
        let normalized = environment.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !isSensitiveEnvironmentKey(key) else { return }
            guard isSafeEnvironmentValue(item.value) else { return }
            result[key] = item.value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isSensitiveEnvironmentKey(_ key: String) -> Bool {
        let uppercasedKey = key.uppercased()
        let sensitiveFragments = [
            "API_KEY",
            "ACCESS_KEY",
            "AUTH_TOKEN",
            "BEARER_TOKEN",
            "PRIVATE_KEY",
            "PASSWORD",
            "PASSWD",
            "SECRET",
            "TOKEN",
            "CREDENTIAL",
            "COOKIE",
        ]
        return sensitiveFragments.contains { uppercasedKey.contains($0) }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SurfaceResumeBindingSnapshot: WorkspaceSurfaceResumeBinding {
    var requiresPromptApproval: Bool {
        approvalPolicy == .prompt
    }
}

/// Conforms the persisted binding snapshot to the CmuxWorkspaces resolution
/// seam so `SessionRestoreCoordinator` can decide stored-vs-process-detected
/// outcomes without importing this wire type. Both witnesses
/// (`isProcessDetected`, `shouldYieldToDetectedSurfaceResumeBinding(_:)`) are
/// already declared on the struct above, so the conformance is satisfied as-is.
extension SurfaceResumeBindingSnapshot: SurfaceResumeBindingResolving {}

nonisolated struct SurfaceResumeApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    var version: Int
    var id: String
    var name: String?
    var commandPrefix: [String]
    var cwd: String?
    var environment: [String: String]?
    var environmentKeys: [String]
    var source: String?
    var policy: SurfaceResumeApprovalPolicy
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastUsedAt: TimeInterval?
    var signature: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String? = nil,
        commandPrefix: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        environmentKeys: [String] = [],
        source: String? = nil,
        policy: SurfaceResumeApprovalPolicy,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        lastUsedAt: TimeInterval? = nil,
        signature: String? = nil
    ) {
        self.version = 1
        self.id = id
        self.name = Self.normalized(name)
        self.commandPrefix = commandPrefix.filter { !$0.isEmpty }
        self.cwd = SurfaceResumeCommandCanonicalizer.normalizedCWD(cwd)
        self.environment = Self.normalizedEnvironment(environment)
        self.environmentKeys = Self.normalizedEnvironmentKeys(environmentKeys, environment: self.environment)
        self.source = Self.normalized(source)
        self.policy = policy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.signature = Self.normalized(signature)
    }

    var commandPrefixText: String {
        commandPrefix.map(SurfaceResumeCommandCanonicalizer.shellQuoted).joined(separator: " ")
    }

    func matches(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        guard !commandPrefix.isEmpty,
              let tokens = SurfaceResumeCommandCanonicalizer.tokens(from: binding.command),
              tokens.count >= commandPrefix.count,
              Array(tokens.prefix(commandPrefix.count)) == commandPrefix else {
            return false
        }
        if let cwd {
            guard SurfaceResumeCommandCanonicalizer.normalizedCWD(binding.cwd) == cwd else {
                return false
            }
        }
        let bindingEnvironment = binding.environment ?? [:]
        guard let environment, !environment.isEmpty else {
            return bindingEnvironment.isEmpty
        }
        return bindingEnvironment == environment
    }

    func signingPayloadData() -> Data {
        let encodedPrefix = commandPrefix
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ",")
        let encodedEnvironmentKeys = environmentKeys
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ",")
        let encodedEnvironment = (environment ?? [:])
            .keys
            .sorted()
            .map { key in
                let value = environment?[key] ?? ""
                return "\(Data(key.utf8).base64EncodedString())=\(Data(value.utf8).base64EncodedString())"
            }
            .joined(separator: ",")
        let fields = [
            "version=\(version)",
            "id=\(id)",
            "name=\(name.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "commandPrefix=\(encodedPrefix)",
            "cwd=\(cwd.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "environment=\(encodedEnvironment)",
            "environmentKeys=\(encodedEnvironmentKeys)",
            "source=\(source.map { Data($0.utf8).base64EncodedString() } ?? "")",
            "policy=\(policy.rawValue)",
            "createdAt=\(createdAt)",
            "updatedAt=\(updatedAt)",
            "lastUsedAt=\(lastUsedAt.map { String($0) } ?? "")",
        ]
        return fields.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    func signed(secret: Data) -> SurfaceResumeApprovalRecord {
        var copy = self
        copy.signature = SurfaceResumeApprovalSignature.sign(copy.signingPayloadData(), secret: secret)
        return copy
    }

    func hasValidSignature(secret: Data) -> Bool {
        guard let signature else { return false }
        return SurfaceResumeApprovalSignature.sign(signingPayloadData(), secret: secret) == signature
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func normalizedEnvironment(_ environment: [String: String]?) -> [String: String]? {
        guard let environment else { return nil }
        let normalized = environment.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            guard isSafeEnvironmentValue(item.value) else { return }
            result[key] = item.value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func normalizedEnvironmentKeys(
        _ environmentKeys: [String],
        environment: [String: String]?
    ) -> [String] {
        let explicitKeys = environmentKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let environmentDerivedKeys: [String] = environment.map { Array($0.keys) } ?? []
        return Array(Set(explicitKeys + environmentDerivedKeys)).sorted()
    }
}

enum SurfaceResumeCommandCanonicalizer {
    static func tokens(from command: String) -> [String]? {
        let scalars = Array(command.unicodeScalars)
        var tokens: [String] = []
        var token = String.UnicodeScalarView()
        var index = 0
        var quote: UnicodeScalar?

        func flushToken() {
            guard !token.isEmpty else { return }
            tokens.append(String(token))
            token.removeAll(keepingCapacity: true)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if let activeQuote = quote {
                if scalar == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", scalar == "\\", index + 1 < scalars.count {
                    index += 1
                    token.append(scalars[index])
                } else {
                    token.append(scalar)
                }
            } else if scalar == "'" || scalar == "\"" {
                quote = scalar
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushToken()
            } else if scalar == "\\", index + 1 < scalars.count {
                index += 1
                token.append(scalars[index])
            } else {
                token.append(scalar)
            }
            index += 1
        }

        guard quote == nil else { return nil }
        flushToken()
        return tokens.isEmpty ? nil : tokens
    }

    static func normalizedCWD(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return ((rawValue as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=./:@%")
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SurfaceResumeApprovalSignature {
    static func sign(_ payload: Data, secret: Data) -> String {
#if canImport(CryptoKit)
        let key = SymmetricKey(data: secret)
        let code = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(code).base64EncodedString()
#else
        return ""
#endif
    }
}

nonisolated enum TerminalStartupReturnShellScript {
    private static let shellLine = #"_cmux_resume_shell="${SHELL:-/bin/zsh}""#
    private static let zshIntegrationReentryLines = [
        #"if [[ "${_cmux_resume_shell:t}" == "zsh" && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" && -r "${CMUX_SHELL_INTEGRATION_DIR}/.zshenv" ]]; then"#,
        #"  if [[ -n "${ZDOTDIR+X}" ]]; then"#,
        #"    export CMUX_ZSH_ZDOTDIR="$ZDOTDIR""#,
        #"  else"#,
        #"    unset CMUX_ZSH_ZDOTDIR"#,
        #"  fi"#,
        #"  export ZDOTDIR="$CMUX_SHELL_INTEGRATION_DIR""#,
        #"fi"#,
    ]

    static func commandThenReturnLines(command: String, workingDirectory: String? = nil) -> [String] {
        let quotedCommand = TerminalStartupShellQuoting().singleQuoted(command)
        var lines = [
            shellLine,
            #"case "${_cmux_resume_shell:t}" in"#,
            #"  zsh|bash) "$_cmux_resume_shell" -lic \#(quotedCommand) ;;"#,
            #"  csh|tcsh) "$_cmux_resume_shell" -c \#(quotedCommand) ;;"#,
            #"  *) "$_cmux_resume_shell" -c \#(quotedCommand) ;;"#,
            #"esac"#,
        ] + zshIntegrationReentryLines
        // The resume command's `cd` runs inside the child shell above, so after the resumed agent
        // exits the outer login shell would otherwise land in this script's launch cwd (the surface
        // default), not the session's directory. Return the outer shell to the session's working
        // directory so killing a resumed agent leaves you where the session lived.
        if let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let quotedDirectory = TerminalStartupShellQuoting().singleQuoted(workingDirectory)
            lines.append(#"{ cd -- \#(quotedDirectory) 2>/dev/null || true; }"#)
        }
        lines.append(#"exec -l "$_cmux_resume_shell""#)
        return lines
    }
}

private enum SurfaceResumeBindingScriptStore {
    private static let directoryName = "cmux-surface-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        inlineInput: String,
        binding: SurfaceResumeBindingSnapshot,
        fileManager: FileManager,
        temporaryDirectory: URL,
        returnToLoginShell: Bool = false
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let prefix = safeFilenamePrefix(binding: binding)
            let scriptURL = directoryURL.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if returnToLoginShell {
                lines.append(contentsOf: TerminalStartupReturnShellScript.commandThenReturnLines(
                    command: inlineInput,
                    workingDirectory: binding.cwd
                ))
            } else {
                lines.append(inlineInput)
            }
            let contents = lines.joined(separator: "\n") + "\n"
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func safeFilenamePrefix(binding: SurfaceResumeBindingSnapshot) -> String {
        let rawPrefix = binding.kind ?? binding.source ?? "surface-resume"
        let safePrefix = rawPrefix
            .prefix(24)
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "-" ? character : "_"
            }
        return safePrefix.isEmpty ? "surface-resume" : String(safePrefix)
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            guard let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: scriptURL)
        }
    }
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
    var agent: SessionRestorableAgentSnapshot?
    var tmuxStartCommand: String?
    var hibernation: SessionAgentHibernationSnapshot?
    var resumeBinding: SurfaceResumeBindingSnapshot?
    var textBoxDraft: SessionTextBoxInputDraftSnapshot?
    var isRemoteTerminal: Bool?
    var remotePTYSessionID: String?
    /// Whether the agent process was actively running when this snapshot was captured.
    /// Nil means unknown (legacy snapshots); treated as true for backwards compatibility.
    var wasAgentRunning: Bool?

    init(
        workingDirectory: String? = nil,
        scrollback: String? = nil,
        agent: SessionRestorableAgentSnapshot? = nil,
        tmuxStartCommand: String? = nil,
        hibernation: SessionAgentHibernationSnapshot? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        textBoxDraft: SessionTextBoxInputDraftSnapshot? = nil,
        isRemoteTerminal: Bool? = nil,
        remotePTYSessionID: String? = nil,
        wasAgentRunning: Bool? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.scrollback = scrollback
        self.agent = agent
        self.tmuxStartCommand = tmuxStartCommand
        self.hibernation = hibernation
        self.resumeBinding = resumeBinding
        self.textBoxDraft = textBoxDraft
        self.isRemoteTerminal = isRemoteTerminal
        self.remotePTYSessionID = remotePTYSessionID
        self.wasAgentRunning = wasAgentRunning
    }
}

extension SessionTerminalPanelSnapshot: WorkspaceSessionRemoteRestoreTerminalSnapshot {}

struct SessionRightSidebarToolPanelSnapshot: Codable, Sendable {
    var mode: RightSidebarMode?

    init(mode: RightSidebarMode?) {
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .mode)
        self.mode = raw.flatMap { RightSidebarMode(rawValue: $0) }
    }
}

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    var isRead: Bool
    var paneFlash: Bool?
    var clickAction: TerminalNotificationClickAction?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.clickAction = clickAction
    }

    init(notification: TerminalNotification) {
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            clickAction: notification.clickAction
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            clickAction: clickAction
        )
    }
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    /// Provenance of `customTitle`. Optional with a `nil` default so snapshots
    /// persisted before provenance existed decode unchanged; restore treats
    /// absent provenance as user-set (the conservative choice for auto-naming).
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var hasUnreadIndicator: Bool? = nil
    var restoredUnreadContributesToWorkspace: Bool? = nil
    var notifications: [SessionNotificationSnapshot]? = nil
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
    var filePreview: SessionFilePreviewPanelSnapshot?
    var rightSidebarTool: SessionRightSidebarToolPanelSnapshot?
    var agentSession: SessionAgentSessionPanelSnapshot? = nil
    var project: SessionProjectPanelSnapshot?
}

extension SessionPanelSnapshot: WorkspaceSessionRemoteRestorePanelSnapshot {}

// The persisted layout DTOs (SessionSplitOrientation, SessionPaneLayoutSnapshot,
// SessionSplitLayoutSnapshot, SessionWorkspaceLayoutSnapshot, and
// SessionCanvasPaneSnapshot) now live in CmuxWorkspaces/Session/, alongside the
// SessionLayoutPruning/SessionLayoutNodeBuilding seams and the session restore
// coordinator that compute over them. They are imported via `import CmuxWorkspaces`.

struct SessionWorkspaceSnapshot: Codable, Sendable {
    /// Original workspace ID captured when the snapshot comes from a live workspace.
    /// Restore uses this to remap closed-panel history onto the new workspace IDs;
    /// legacy or externally-created snapshots can leave it nil.
    var workspaceId: UUID? = nil
    var processTitle: String
    var customTitle: String?
    /// Provenance of `customTitle`. Optional with a `nil` default so snapshots
    /// persisted before provenance existed decode unchanged; restore treats
    /// absent provenance as user-set (the conservative choice for auto-naming).
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var customDescription: String?
    var customColor: String?
    var isPinned: Bool
    var groupId: UUID? = nil
    var isManuallyUnread: Bool? = nil
    var hasUnreadIndicator: Bool? = nil
    var notifications: [SessionNotificationSnapshot]? = nil
    var terminalScrollBarHidden: Bool?
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    /// `WorkspaceLayoutMode` raw value; absent in pre-canvas snapshots
    /// (treated as splits).
    var layoutMode: String? = nil
    /// Canvas pane frames in z-order; persisted whenever any exist so
    /// positions survive toggling back to splits across restarts.
    var canvasPanes: [SessionCanvasPaneSnapshot]? = nil
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
    var remote: SessionRemoteWorkspaceSnapshot?
    /// User-defined per-workspace environment variables (issue #5995). Optional
    /// with a `nil` default so manifests written before this field decode cleanly.
    var environment: [String: String]? = nil
}

extension SessionWorkspaceSnapshot: WorkspaceSessionRemoteRestoreSnapshot {}

// `SessionWorkspaceGroupSnapshot` moved to CmuxWorkspaces
// (Session/SessionWorkspaceGroupSnapshot.swift) so the package-owned snapshot
// assembly/restore math (SessionSnapshotGroupCoordinator) speaks it directly.
// The Codable wire format is unchanged; this file imports it via CmuxWorkspaces.

extension SessionWorkspaceSnapshot {
    var hasRestorablePanels: Bool {
        !panels.isEmpty
    }
}

extension SessionWindowSnapshot {
    var hasRestorablePanels: Bool {
        tabManager.workspaces.contains { $0.hasRestorablePanels }
    }
}

struct SessionTabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
    var workspaceGroups: [SessionWorkspaceGroupSnapshot]? = nil
}

struct SessionWindowSnapshot: Codable, Sendable {
    var windowId: UUID? = nil
    var frame: SessionRectSnapshot?
    var display: SessionDisplaySnapshot?
    var tabManager: SessionTabManagerSnapshot
    var sidebar: SessionSidebarSnapshot
}

struct AppSessionSnapshot: Codable, Sendable {
    var version: Int
    var createdAt: TimeInterval
    var windows: [SessionWindowSnapshot]
}

extension AppSessionSnapshot: SessionSnapshotRepresenting {
    /// Whether the snapshot carries at least one window. The `CmuxSession`
    /// repository treats an empty-window snapshot as unusable (empty states
    /// remove the file instead of writing it), matching the legacy
    /// `!snapshot.windows.isEmpty` usability check.
    var hasWindows: Bool { !windows.isEmpty }
}
