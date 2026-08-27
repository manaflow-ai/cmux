import CoreGraphics
import CMUXAgentLaunch
import CmuxBrowser
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
    // Keep the default equal to the minimum so a fresh sidebar starts at the minimum width.
    // The titlebar title tracks the sidebar's actual width only when it is wider than the
    // minimum, so a default above the minimum would make the folder/title shift when toggling the sidebar at the default width.
    static let defaultSidebarWidth: Double = 240
    static let defaultMinimumSidebarWidth: Double = 240
    static let minimumSidebarWidth: Double = 240
    static let sidebarMinimumWidthRange: ClosedRange<Double> = 120...260
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512
    static let maxScrollbackLinesPerTerminal: Int = 4000
    static let maxScrollbackCharactersPerTerminal: Int = 400_000

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

    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxScrollbackCharactersPerTerminal {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance to
    /// the first printable character after that sequence to avoid replaying malformed control bytes.
    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        // If a final CSI byte exists before the truncation boundary, we are not
        // inside a partial sequence.
        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        // We are inside a CSI sequence. Skip to the first character after the
        // sequence terminator if it exists.
        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum SessionRestorePolicy {
    static func isRunningUnderAutomatedTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CMUX_TEST_PROCESS"] == "1" {
            return true
        }
        if environment["CMUX_UI_TEST_MODE"] == "1" {
            return true
        }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if environment["XCInjectBundle"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    static func shouldAttemptRestore(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CMUX_DISABLE_SESSION_RESTORE"] == "1" {
            return false
        }
        if isRunningUnderAutomatedTests(environment: environment) {
            return false
        }

        let extraArgs = arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-psn_") }

        // Any explicit launch argument is treated as an explicit open intent.
        return extraArgs.isEmpty
    }
}

struct SessionRectSnapshot: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    case tabs
    case notifications

    init(selection: SidebarSelection) {
        switch selection {
        case .tabs, .notifications:
            // Notifications moved from a window-level overlay to a pane tab.
            // Never persist the retired overlay selection.
            self = .tabs
        }
    }

    var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            // Migrate snapshots written by builds that used the overlay.
            return .tabs
        }
    }
}

struct SessionSidebarSnapshot: Codable, Sendable {
    var isVisible: Bool
    var selection: SessionSidebarSelection
    var width: Double?
}

struct SessionStatusEntrySnapshot: Codable, Sendable {
    var key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: TimeInterval
}

struct SessionLogEntrySnapshot: Codable, Sendable {
    var message: String
    var level: String
    var source: String?
    var timestamp: TimeInterval
}

struct SessionProgressSnapshot: Codable, Sendable {
    var value: Double
    var label: String?
}

struct SessionGitBranchSnapshot: Codable, Sendable {
    var branch: String
    var isDirty: Bool
}

enum SurfaceResumeApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case manual
    case prompt
    case auto
}

struct SurfaceResumeBindingSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case name, kind, command, cwd, checkpointId, source
        case environment, autoResume, approvalPolicy, approvalRecordId
        case launchCommand, permissionMode, launchFlavor, updatedAt
        case restoreWorkingDirectorySelection
        case resumeEvidenceProvenance
    }

    var name: String?
    var kind: String?
    var command: String
    var cwd: String?
    var checkpointId: String?
    var source: String?
    var environment: [String: String]?
    var launchCommand: AgentLaunchCommandSnapshot?
    var permissionMode: String?
    /// Persisted cwd trust boundary for agent-hook restore bindings.
    var restoreWorkingDirectorySelection: AgentRestoreWorkingDirectorySelection?
    var autoResume: Bool?
    /// Verified Codex hook provenance carried into the app-owned atomic gate.
    /// Non-Codex and legacy bindings leave this unset.
    var resumeEvidenceProvenance: String?
    var approvalPolicy: SurfaceResumeApprovalPolicy?
    var approvalRecordId: String?
    var launchFlavor: SurfaceResumeLaunchFlavor
    /// Whether decoding observed a legacy binding without an execution location.
    private(set) var wasDecodedWithoutLaunchFlavor = false
    var updatedAt: TimeInterval

    init(
        name: String? = nil,
        kind: String? = nil,
        command: String,
        cwd: String? = nil,
        checkpointId: String? = nil,
        source: String? = nil,
        environment: [String: String]? = nil,
        launchCommand: AgentLaunchCommandSnapshot? = nil,
        permissionMode: String? = nil,
        restoreWorkingDirectorySelection: AgentRestoreWorkingDirectorySelection? = nil,
        autoResume: Bool? = nil,
        resumeEvidenceProvenance: String? = nil,
        approvalPolicy: SurfaceResumeApprovalPolicy? = nil,
        approvalRecordId: String? = nil,
        launchFlavor: SurfaceResumeLaunchFlavor = .local,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalizedCwd = Self.normalized(cwd)
        let normalizedKind = Self.normalized(kind)
        let normalizedSource = Self.normalized(source)
        self.name = Self.normalized(name)
        self.kind = normalizedKind
        self.command = Self.sanitizedStartupCommand(
            command,
            cwd: normalizedCwd,
            source: normalizedSource,
            agentKind: normalizedKind
        )
        self.cwd = normalizedCwd
        self.checkpointId = Self.normalized(checkpointId)
        self.source = normalizedSource
        self.environment = Self.normalizedEnvironment(environment)
        self.launchCommand = Self.normalizedLaunchCommand(launchCommand)
        self.permissionMode = Self.normalized(permissionMode)
        self.restoreWorkingDirectorySelection = restoreWorkingDirectorySelection
        self.autoResume = autoResume
        let retainsCodexEvidence = normalizedSource?.lowercased() == "agent-hook"
            && normalizedKind?.lowercased() == "codex"
        self.resumeEvidenceProvenance = retainsCodexEvidence
            ? Self.normalized(resumeEvidenceProvenance)
            : nil
        self.approvalPolicy = approvalPolicy
        self.approvalRecordId = Self.normalized(approvalRecordId)
        self.launchFlavor = launchFlavor
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLaunchFlavor = try container.decodeIfPresent(SurfaceResumeLaunchFlavor.self, forKey: .launchFlavor)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            kind: try container.decodeIfPresent(String.self, forKey: .kind),
            command: try container.decode(String.self, forKey: .command),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            checkpointId: try container.decodeIfPresent(String.self, forKey: .checkpointId),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            environment: try container.decodeIfPresent([String: String].self, forKey: .environment),
            launchCommand: try container.decodeIfPresent(
                AgentLaunchCommandSnapshot.self,
                forKey: .launchCommand
            ),
            permissionMode: try container.decodeIfPresent(String.self, forKey: .permissionMode),
            restoreWorkingDirectorySelection: try container.decodeIfPresent(
                AgentRestoreWorkingDirectorySelection.self,
                forKey: .restoreWorkingDirectorySelection
            ),
            autoResume: try container.decodeIfPresent(Bool.self, forKey: .autoResume),
            resumeEvidenceProvenance: try container.decodeIfPresent(String.self, forKey: .resumeEvidenceProvenance),
            approvalPolicy: try container.decodeIfPresent(SurfaceResumeApprovalPolicy.self, forKey: .approvalPolicy),
            approvalRecordId: try container.decodeIfPresent(String.self, forKey: .approvalRecordId),
            launchFlavor: decodedLaunchFlavor ?? .local,
            updatedAt: try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt)
                ?? Date().timeIntervalSince1970
        )
        wasDecodedWithoutLaunchFlavor = decodedLaunchFlavor == nil
    }

    var isProcessDetected: Bool {
        source == "process-detected"
    }

    /// Plain interactive SSH bindings are intentionally durable across a
    /// restore pass.  Their process is expected to be absent while the new
    /// local PTY is starting, so a transiently empty process scan must not
    /// erase the command before the next autosave can observe it again.
    var isPlainSSHProcessDetectedBinding: Bool {
        isProcessDetected && kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ssh"
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

    /// Keeps an uncertain binding available for manual continuation without
    /// allowing a stale process observation to launch on the next restore.
    func disablingAutomaticResume() -> Self {
        guard autoResume == true else { return self }
        var disabled = self
        disabled.autoResume = false
        disabled.approvalPolicy = .manual
        return disabled
    }

    var usesLocalRestoreVerb: Bool {
        launchFlavor == .local
    }

    func shouldYieldToDetectedSurfaceResumeBinding(_ detectedBinding: SurfaceResumeBindingSnapshot) -> Bool {
        detectedBinding.isProcessDetected && (isProcessDetected || isAgentHookBinding)
    }

    func retargetingWorkingDirectory(_ workingDirectory: String?) -> SurfaceResumeBindingSnapshot {
        guard isAgentHookBinding else { return self }
        let normalizedCwd = Self.normalized(workingDirectory)
        var retargeted = self
        retargeted.command = TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: command,
            previousWorkingDirectory: cwd,
            workingDirectory: normalizedCwd,
            agentKind: Self.normalized(kind)
        )
        retargeted.cwd = normalizedCwd
        if var launchCommand = retargeted.launchCommand {
            launchCommand.workingDirectory = normalizedCwd
            retargeted.launchCommand = launchCommand
        }
        return retargeted
    }
    var startupInput: String? {
        inlineStartupInput
    }

    var inlineStartupInput: String? {
        inlineStartupInput(repairPortableAgentExecutable: true)
    }

    func restoreStartupInput() -> String? {
        restoreStartupInput(repairPortableAgentExecutable: true)
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

    private static func normalizedLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?
    ) -> AgentLaunchCommandSnapshot? {
        guard var launchCommand else { return nil }
        launchCommand.workingDirectory = normalized(launchCommand.workingDirectory)
        launchCommand.verificationHome = normalized(launchCommand.verificationHome)
        launchCommand.environment = normalizedEnvironment(launchCommand.environment)
        return launchCommand
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

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SurfaceResumeBindingSnapshot: WorkspaceSurfaceResumeBinding {
    var requiresPromptApproval: Bool {
        approvalPolicy == .prompt
    }
}

struct SurfaceResumeApprovalRecord: Codable, Equatable, Identifiable, Sendable {
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
        // Remote approvals require a follow-up location-scoped record design that
        // persists and signs an execution-location field.
        guard binding.launchFlavor == .local,
              !commandPrefix.isEmpty,
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
        if let environment, !environment.isEmpty {
            guard bindingEnvironment == environment else { return false }
        } else {
            guard bindingEnvironment.isEmpty else { return false }
        }
        return SurfaceResumeCommandCanonicalizer.isShellExpansionSafeCommand(binding.command)
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
        tokensWithRawSlices(from: command)?.map(\.token)
    }

    static func tokensWithRawSlices(
        from command: String
    ) -> [(token: String, raw: Substring)]? {
        let scalars = command.unicodeScalars
        var tokens: [(token: String, raw: Substring)] = []
        var token = String.UnicodeScalarView()
        var rawStart: String.Index?
        var index = scalars.startIndex
        var quote: UnicodeScalar?

        func flushToken(endingAt endIndex: String.Index) {
            defer {
                token.removeAll(keepingCapacity: true)
                rawStart = nil
            }
            guard !token.isEmpty, let rawStart else { return }
            tokens.append((
                token: String(token),
                raw: command[rawStart..<endIndex]
            ))
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if let activeQuote = quote {
                if scalar == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", scalar == "\\" {
                    let nextIndex = scalars.index(after: index)
                    guard nextIndex < scalars.endIndex else {
                        index = nextIndex
                        continue
                    }
                    index = nextIndex
                    token.append(scalars[index])
                } else {
                    token.append(scalar)
                }
            } else if scalar == "'" || scalar == "\"" {
                rawStart = rawStart ?? index
                quote = scalar
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushToken(endingAt: index)
            } else if scalar == "\\" {
                rawStart = rawStart ?? index
                let nextIndex = scalars.index(after: index)
                guard nextIndex < scalars.endIndex else {
                    token.append(scalar)
                    index = nextIndex
                    continue
                }
                index = nextIndex
                token.append(scalars[index])
            } else {
                rawStart = rawStart ?? index
                token.append(scalar)
            }
            index = scalars.index(after: index)
        }

        guard quote == nil else { return nil }
        flushToken(endingAt: scalars.endIndex)
        return tokens.isEmpty ? nil : tokens
    }

    static func isShellExpansionSafeCommand(_ command: String) -> Bool {
        tokensWithRawSlices(from: command) != nil &&
            !containsUnsafeShellControl(command[...])
    }

    static func generalizedApprovalPrefix(forCommand command: String) -> [String]? {
        guard isShellExpansionSafeCommand(command),
              let tokens = tokens(from: command) else {
            return nil
        }

        var prefix: [String] = []
        var index = tokens.startIndex

        while index < tokens.endIndex, isEnvironmentAssignment(tokens[index]) {
            prefix.append(tokens[index])
            index = tokens.index(after: index)
        }

        if index < tokens.endIndex, tokens[index] == "env" || tokens[index] == "/usr/bin/env" {
            prefix.append(tokens[index])
            index = tokens.index(after: index)
            while index < tokens.endIndex, isEnvironmentAssignment(tokens[index]) {
                prefix.append(tokens[index])
                index = tokens.index(after: index)
            }
        }

        guard index < tokens.endIndex else {
            return nil
        }
        let commandToken = tokens[index]
        // `env` flags (e.g. `env -i`) or a nested `env` would make the wrapper
        // itself the scoped command, so the generalized prefix would match
        // arbitrary commands; fail closed instead.
        guard !commandToken.hasPrefix("-"),
              commandToken != "env",
              commandToken != "/usr/bin/env" else {
            return nil
        }
        prefix.append(commandToken)
        index = tokens.index(after: index)

        while index < tokens.endIndex {
            let token = tokens[index]
            guard token.hasPrefix("-") || token == "resume" else {
                break
            }
            prefix.append(token)
            index = tokens.index(after: index)
        }

        // The generalized scope may only leave the session id itself
        // unmatched. Arguments after the session id (`codex resume <id>
        // --yolo`) would be dropped from the scope and prefix matching would
        // re-authorize a different session with different options, so fail
        // closed instead of widening the policy.
        guard tokens.count == prefix.count + 1 else {
            return nil
        }
        return prefix
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

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "=") else {
            return false
        }
        let nameScalars = token[..<equalsIndex].unicodeScalars
        guard let firstScalar = nameScalars.first,
              isEnvironmentNameStart(firstScalar) else {
            return false
        }
        return nameScalars.dropFirst().allSatisfy(isEnvironmentNameContinuation)
    }

    private static func containsUnsafeShellControl(_ raw: Substring) -> Bool {
        let scalars = raw.unicodeScalars
        var index = scalars.startIndex
        var quote: UnicodeScalar?
        var isAtTokenStart = true

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if quote == "'" {
                if scalar == "'" {
                    quote = nil
                }
                index = scalars.index(after: index)
                continue
            }
            if quote == "\"" {
                if scalar == "\\" {
                    let nextIndex = scalars.index(after: index)
                    index = nextIndex < scalars.endIndex
                        ? scalars.index(after: nextIndex)
                        : nextIndex
                    continue
                }
                if scalar == "\"" {
                    quote = nil
                } else if scalar == "$" || scalar == "`" || scalar == "!" ||
                            scalar == "\n" || scalar == "\r" {
                    return true
                }
                index = scalars.index(after: index)
                continue
            }
            if scalar == "\\" {
                isAtTokenStart = false
                let nextIndex = scalars.index(after: index)
                index = nextIndex < scalars.endIndex
                    ? scalars.index(after: nextIndex)
                    : nextIndex
                continue
            }
            if scalar == "'" {
                isAtTokenStart = false
                quote = scalar
            } else if scalar == "\"" {
                isAtTokenStart = false
                quote = scalar
            } else if scalar == "$" || scalar == "`" || scalar == "!" ||
                        scalar == "\n" || scalar == "\r" {
                return true
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                isAtTokenStart = true
            } else if scalar == "*" || scalar == "?" || scalar == "[" ||
                        scalar == "{" || scalar == "}" {
                return true
            } else if isAtTokenStart && (scalar == "~" || scalar == "=") {
                return true
            } else if scalar == ";" || scalar == "|" || scalar == "&" ||
                      scalar == "<" || scalar == ">" || scalar == "(" || scalar == ")" {
                return true
            } else {
                isAtTokenStart = false
            }
            index = scalars.index(after: index)
        }
        return false
    }

    private static func isEnvironmentNameStart(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isEnvironmentNameContinuation(_ scalar: UnicodeScalar) -> Bool {
        isEnvironmentNameStart(scalar) ||
            (scalar.value >= 48 && scalar.value <= 57)
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

enum SurfaceResumeApprovalStore {
    static let didChangeNotification = Notification.Name("cmux.surfaceResumeApprovalsDidChange")
    private static let legacyFileName = "resume-commands.json"
    private static let secretFileName = ".surface-resume-approval-secret"
    private static let settingsTerminalSectionKey = "terminal"
    private static let settingsRecordsKey = "resumeCommands"
    private static let keychainService = "com.cmuxterm.app.surface-resume-approvals"
    private static let keychainAccount = "hmac-secret-v1"
    private static let signingSecretCache = SurfaceResumeApprovalSigningSecretCache(
        loader: {
            SurfaceResumeApprovalStore.loadOrCreateSigningSecret(fileManager: .default)
        },
        schedule: { job in
            SurfaceResumeApprovalSigningSecretCache.utilityTask(job)
        }
    )

    struct StoredFile: Codable {
        var version: Int
        var records: [SurfaceResumeApprovalRecord]
    }

    private enum CmuxSettingsRootLoadResult {
        case missing
        case invalid
        case parsed([String: Any])
    }

    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CMUX_SURFACE_RESUME_APPROVAL_STORE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: false)
        }
        return URL(fileURLWithPath: CmuxSettingsFileStore.defaultPrimaryPath, isDirectory: false)
    }

    static func loadRecords(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        defaultSettingsURL: URL = defaultURL()
    ) -> [SurfaceResumeApprovalRecord] {
        if storesRecordsInCmuxSettings(fileURL) {
            let loaded = loadRecordsFromCmuxSettings(fileURL: fileURL)
            if loaded.hasResumeCommandsKey {
                return loaded.records
            }
            guard fileURL.standardizedFileURL.path == defaultSettingsURL.standardizedFileURL.path else {
                return loaded.records
            }
            let legacyURL = legacyURL(forCmuxSettingsURL: fileURL)
            let legacyRecords = loadStandaloneRecords(fileURL: legacyURL, fileManager: fileManager)
            guard !legacyRecords.isEmpty else {
                return loaded.records
            }
            guard loaded.canWriteSettings else {
                return legacyRecords
            }
            _ = migrateLegacyRecordsIfNeeded(
                fileURL: fileURL,
                fileManager: fileManager,
                legacyFileURL: legacyURL
            )
            return legacyRecords
        }
        return loadStandaloneRecords(fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func migrateLegacyRecordsIfNeeded(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        legacyFileURL: URL? = nil
    ) -> Bool {
        guard storesRecordsInCmuxSettings(fileURL) else {
            return false
        }
        let loaded = loadRecordsFromCmuxSettings(fileURL: fileURL)
        guard !loaded.hasResumeCommandsKey else {
            return false
        }
        guard loaded.canWriteSettings else {
            return false
        }
        let legacyURL = legacyFileURL ?? legacyURL(forCmuxSettingsURL: fileURL)
        let legacyRecords = loadStandaloneRecords(fileURL: legacyURL, fileManager: fileManager)
        guard !legacyRecords.isEmpty else {
            return false
        }
        return writeRecordsToCmuxSettings(records: legacyRecords, fileURL: fileURL, fileManager: fileManager)
    }

    private static func loadStandaloneRecords(
        fileURL: URL,
        fileManager: FileManager
    ) -> [SurfaceResumeApprovalRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        if let file = try? JSONDecoder().decode(StoredFile.self, from: data) {
            return file.records
        }
        return (try? JSONDecoder().decode([SurfaceResumeApprovalRecord].self, from: data)) ?? []
    }

    static func shouldPromptForProposal(
        binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?,
        isMainThread: Bool,
        isRunningTests: Bool
    ) -> Bool {
        guard binding.launchFlavor == .local else {
            return false
        }
        guard isMainThread else {
            return false
        }
        guard !isRunningTests else {
            return false
        }
        guard !binding.isCLIBinding else {
            return false
        }
        guard !binding.isProcessDetected, !binding.isAgentHookBinding else {
            return false
        }
        guard SurfaceResumeCommandCanonicalizer.isShellExpansionSafeCommand(binding.command) else {
            return false
        }
        guard let existingRecord else { return true }
        return existingRecord.policy == .prompt
    }

    static func applyingPromptlessCLIManualApprovalIfNeeded(
        to binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeBindingSnapshot? {
        guard binding.isCLIBinding, existingRecord == nil else {
            return nil
        }
        guard let record = approve(
            binding: binding,
            policy: .manual,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        ) else {
            return nil
        }
        var effectiveBinding = binding
        effectiveBinding.approvalPolicy = record.policy
        effectiveBinding.approvalRecordId = record.id
        effectiveBinding.autoResume = record.policy == .auto
        return effectiveBinding
    }

    @discardableResult
    static func approve(
        binding: SurfaceResumeBindingSnapshot,
        policy: SurfaceResumeApprovalPolicy,
        commandPrefix: [String]? = nil,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalRecord? {
        // Location-scoped signed records are the follow-up if remote approvals are wanted.
        guard binding.launchFlavor == .local else {
            return nil
        }
        guard SurfaceResumeCommandCanonicalizer.isShellExpansionSafeCommand(binding.command) else {
            return nil
        }
        let resolution = signingSecretResolution(explicit: signingSecret, fileManager: fileManager)
        guard case let .ready(signingSecret?) = resolution,
              let tokens = SurfaceResumeCommandCanonicalizer.tokens(from: binding.command) else {
            return nil
        }
        let prefix = commandPrefix ?? tokens
        guard !prefix.isEmpty, tokens.count >= prefix.count, Array(tokens.prefix(prefix.count)) == prefix else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        var records = loadRecords(fileURL: fileURL, fileManager: fileManager)
        let validRecords = records.filter { $0.hasValidSignature(secret: signingSecret) }
        let matchingRecords = validRecords.filter { $0.matches(binding) }
        let existingWithSamePrefix = matchingRecords.first { $0.commandPrefix == prefix }
        let record = SurfaceResumeApprovalRecord(
            id: existingWithSamePrefix?.id ?? UUID().uuidString.lowercased(),
            name: binding.name,
            commandPrefix: prefix,
            cwd: binding.cwd,
            environment: binding.environment,
            environmentKeys: Array((binding.environment ?? [:]).keys),
            source: binding.source,
            policy: policy,
            createdAt: existingWithSamePrefix?.createdAt ?? now,
            updatedAt: now,
            lastUsedAt: existingWithSamePrefix?.lastUsedAt,
            signature: nil
        ).signed(secret: signingSecret)
        let subsumedRecordIds = Set(
            validRecords
                .filter {
                    $0.commandPrefix.count > prefix.count &&
                        $0.commandPrefix.starts(with: prefix) &&
                        $0.cwd == record.cwd &&
                        $0.environment == record.environment
                }
                .map(\.id)
        )
        records.removeAll { subsumedRecordIds.contains($0.id) }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        guard write(records: records, fileURL: fileURL, fileManager: fileManager) else {
            return nil
        }
        return record
    }

    @discardableResult
    static func update(
        recordId: String,
        policy: SurfaceResumeApprovalPolicy? = nil,
        commandPrefix: [String]? = nil,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> Bool {
        let resolution = signingSecretResolution(explicit: signingSecret, fileManager: fileManager)
        guard case let .ready(signingSecret?) = resolution else { return false }
        var records = loadRecords(fileURL: fileURL, fileManager: fileManager)
        guard let index = records.firstIndex(where: { $0.id == recordId }) else { return false }
        var record = records[index]
        guard record.hasValidSignature(secret: signingSecret) else { return false }
        if let policy {
            record.policy = policy
        }
        if let commandPrefix {
            guard !commandPrefix.isEmpty else { return false }
            record.commandPrefix = commandPrefix
        }
        record.updatedAt = Date().timeIntervalSince1970
        records[index] = record.signed(secret: signingSecret)
        return write(records: records, fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func delete(
        recordId: String,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        let records = loadRecords(fileURL: fileURL, fileManager: fileManager)
            .filter { $0.id != recordId }
        return write(records: records, fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func removeAll(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        if storesRecordsInCmuxSettings(fileURL) {
            return write(records: [], fileURL: fileURL, fileManager: fileManager)
        }
        try? fileManager.removeItem(at: fileURL)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return true
    }

    static func defaultSigningSecret(
        fileManager: FileManager = .default
    ) -> SurfaceResumeApprovalSigningSecretResolution {
        if let data = environmentSigningSecret() {
            return .ready(data)
        }
        if fileManager === FileManager.default {
            return signingSecretCache.value(isMainThread: Thread.isMainThread)
        }
        guard !Thread.isMainThread else { return .ready(nil) }
        return .ready(loadOrCreateSigningSecret(fileManager: fileManager))
    }

    /// Starts the one-time Keychain/file lookup early while preserving the
    /// nonblocking contract for the app's main thread.
    static func preloadSigningSecret() {
        guard environmentSigningSecret() == nil else { return }
        signingSecretCache.preload { _ in }
    }

    static var signingSecretIsReady: Bool {
        environmentSigningSecret() != nil || signingSecretCache.isReady
    }

    static func whenSigningSecretReady(_ action: @escaping @Sendable () -> Void) {
        guard environmentSigningSecret() == nil else {
            action()
            return
        }
        signingSecretCache.preload { _ in action() }
    }

    private static func environmentSigningSecret() -> Data? {
        guard let encoded = ProcessInfo.processInfo.environment["CMUX_SURFACE_RESUME_APPROVAL_SECRET_B64"],
              let data = Data(base64Encoded: encoded),
              !data.isEmpty else {
            return nil
        }
        return data
    }

    private static func loadOrCreateSigningSecret(fileManager: FileManager) -> Data? {
        if let data = keychainSecret(), !data.isEmpty {
            return data
        }
        let generated = randomSecret()
        if storeKeychainSecret(generated) {
            return generated
        }
        return fileBackedSecret(fileManager: fileManager, generated: generated)
    }

    @discardableResult
    private static func write(
        records: [SurfaceResumeApprovalRecord],
        fileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        if storesRecordsInCmuxSettings(fileURL) {
            return writeRecordsToCmuxSettings(records: records, fileURL: fileURL, fileManager: fileManager)
        }
        return writeStandaloneRecords(records: records, fileURL: fileURL, fileManager: fileManager)
    }

    @discardableResult
    private static func writeStandaloneRecords(
        records: [SurfaceResumeApprovalRecord],
        fileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(StoredFile(version: 1, records: records))
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    private static func storesRecordsInCmuxSettings(_ fileURL: URL) -> Bool {
        fileURL.lastPathComponent == "cmux.json"
    }

    private static func legacyURL(forCmuxSettingsURL fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(legacyFileName, isDirectory: false)
    }

    private static func loadRecordsFromCmuxSettings(
        fileURL: URL
    ) -> (records: [SurfaceResumeApprovalRecord], hasResumeCommandsKey: Bool, canWriteSettings: Bool) {
        let root: [String: Any]
        switch loadCmuxSettingsRoot(fileURL: fileURL) {
        case .missing:
            return ([], false, true)
        case .invalid:
            return ([], false, false)
        case .parsed(let parsedRoot):
            root = parsedRoot
        }
        guard let terminalSection = root[settingsTerminalSectionKey] as? [String: Any],
              let rawRecords = terminalSection[settingsRecordsKey] else {
            return ([], false, true)
        }
        guard JSONSerialization.isValidJSONObject(rawRecords),
              let data = try? JSONSerialization.data(withJSONObject: rawRecords, options: []),
              let records = try? JSONDecoder().decode([SurfaceResumeApprovalRecord].self, from: data) else {
            return ([], true, true)
        }
        return (records, true, true)
    }

    private static func loadCmuxSettingsRoot(fileURL: URL) -> CmuxSettingsRootLoadResult {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return .missing
        }
        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            guard let root = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any] else {
                return .invalid
            }
            return .parsed(root)
        } catch {
            return .invalid
        }
    }

    @discardableResult
    private static func writeRecordsToCmuxSettings(
        records: [SurfaceResumeApprovalRecord],
        fileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            let rootLoadResult = loadCmuxSettingsRoot(fileURL: fileURL)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let recordsData = try encoder.encode(records)
            let recordsValue = try JSONSerialization.jsonObject(with: recordsData, options: [])
            guard let recordsJSON = String(data: recordsData, encoding: .utf8) else {
                return false
            }

            let data: Data
            switch rootLoadResult {
            case .missing:
                let root: [String: Any] = [
                    "$schema": CmuxSettingsFileStore.schemaURLString,
                    "schemaVersion": CmuxSettingsFileStore.currentSchemaVersion,
                    settingsTerminalSectionKey: [
                        settingsRecordsKey: recordsValue,
                    ],
                ]
                guard JSONSerialization.isValidJSONObject(root) else {
                    return false
                }
                data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            case .invalid:
                return false
            case .parsed:
                guard let existingData = fileManager.contents(atPath: fileURL.path),
                      let decodedSource = try? JSONCParser.source(data: existingData),
                      let updatedSource = JSONCObjectEditor.setNestedObjectProperty(
                          parentKey: settingsTerminalSectionKey,
                          childKey: settingsRecordsKey,
                          childValueJSON: recordsJSON,
                          in: decodedSource.text
                      ) else {
                    return false
                }
                guard let updatedData = updatedSource.data(using: decodedSource.encoding) else {
                    return false
                }
                let sanitized = try JSONCParser.preprocess(data: updatedData)
                guard let root = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any],
                      JSONSerialization.isValidJSONObject(root) else {
                    return false
                }
                data = updatedData
            }

            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    private static func randomSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
#if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return Data(bytes)
        }
#endif
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }

    private static func fileBackedSecret(fileManager: FileManager, generated: Data) -> Data? {
        let url = defaultURL().deletingLastPathComponent().appendingPathComponent(secretFileName, isDirectory: false)
        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            return existing
        }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try generated.write(to: url, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return generated
        } catch {
            return nil
        }
    }

#if canImport(Security)
    private static func keychainSecret() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func storeKeychainSecret(_ secret: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }
        var insert = query
        insert[kSecValueData as String] = secret
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
#else
    private static func keychainSecret() -> Data? { nil }
    private static func storeKeychainSecret(_ secret: Data) -> Bool { false }
#endif
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    /// Explicit, unscaled surface font override. Nil follows the current config.
    var fontSize: Float?
    /// In-flight workspace font requests already represented by `fontSize`.
    /// Close-history restores preserve these tokens to avoid replaying a
    /// projected request while its coordinator still owns the request.
    var fontSizeChangeTokens: [UUID]?
    var scrollback: String?
    var agent: SessionRestorableAgentSnapshot?
    var tmuxStartCommand: String?
    var hibernation: SessionAgentHibernationSnapshot?
    var resumeBinding: SurfaceResumeBindingSnapshot?
    /// Agent-hook identity kept separately when a process-detected binding is
    /// the effective terminal resume target.
    var managedAgentResumeBinding: SurfaceResumeBindingSnapshot?
    var textBoxDraft: SessionTextBoxInputDraftSnapshot?
    var isRemoteTerminal: Bool?
    var remotePTYSessionID: String?
    /// Whether the agent process was actively running when this snapshot was captured.
    /// Nil means unknown (legacy snapshots); treated as true for backwards compatibility.
    var wasAgentRunning: Bool?

    init(
        workingDirectory: String? = nil,
        fontSize: Float? = nil,
        fontSizeChangeTokens: [UUID]? = nil,
        scrollback: String? = nil,
        agent: SessionRestorableAgentSnapshot? = nil,
        tmuxStartCommand: String? = nil,
        hibernation: SessionAgentHibernationSnapshot? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        managedAgentResumeBinding: SurfaceResumeBindingSnapshot? = nil,
        textBoxDraft: SessionTextBoxInputDraftSnapshot? = nil,
        isRemoteTerminal: Bool? = nil,
        remotePTYSessionID: String? = nil,
        wasAgentRunning: Bool? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.fontSize = fontSize
        self.fontSizeChangeTokens = fontSizeChangeTokens
        self.scrollback = scrollback
        self.agent = agent
        self.tmuxStartCommand = tmuxStartCommand
        self.hibernation = hibernation
        self.resumeBinding = resumeBinding
        self.managedAgentResumeBinding = managedAgentResumeBinding
        self.textBoxDraft = textBoxDraft
        self.isRemoteTerminal = isRemoteTerminal
        self.remotePTYSessionID = remotePTYSessionID
        self.wasAgentRunning = wasAgentRunning
    }
}

extension SessionTerminalPanelSnapshot: WorkspaceSessionRemoteRestoreTerminalSnapshot {}

struct SessionAgentHibernationSnapshot: Codable, Sendable {
    var hibernatedAt: TimeInterval
    var lastActivityAt: TimeInterval
}

struct SessionTextBoxInputDraftSnapshot: Codable, Equatable, Sendable {
    var isActive: Bool
    var parts: [SessionTextBoxInputDraftPart]
}

struct SessionTextBoxInputDraftPart: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case attachment
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case attachment
    }

    let kind: Kind
    let text: String?
    let attachment: SessionTextBoxInputAttachmentSnapshot?

    private init(kind: Kind, text: String?, attachment: SessionTextBoxInputAttachmentSnapshot?) {
        self.kind = kind
        self.text = text
        self.attachment = attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let attachment = try container.decodeIfPresent(
            SessionTextBoxInputAttachmentSnapshot.self,
            forKey: .attachment
        )

        switch kind {
        case .text:
            guard text != nil, attachment == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .text,
                    in: container,
                    debugDescription: "Text draft parts must contain text and no attachment."
                )
            }
        case .attachment:
            guard attachment != nil, text == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .attachment,
                    in: container,
                    debugDescription: "Attachment draft parts must contain an attachment and no text."
                )
            }
        }

        self.kind = kind
        self.text = text
        self.attachment = attachment
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(attachment, forKey: .attachment)
    }

    static func text(_ text: String) -> SessionTextBoxInputDraftPart {
        SessionTextBoxInputDraftPart(kind: .text, text: text, attachment: nil)
    }

    static func attachment(_ attachment: SessionTextBoxInputAttachmentSnapshot) -> SessionTextBoxInputDraftPart {
        SessionTextBoxInputDraftPart(kind: .attachment, text: nil, attachment: attachment)
    }
}

struct SessionTextBoxInputAttachmentSnapshot: Codable, Equatable, Sendable {
    var displayName: String
    var submissionText: String
    var submissionPath: String
    var localPath: String?
    var cleanupLocalPathWhenDisposed: Bool
}

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var isMuted: Bool
    var chromeVisibility: BrowserChromeVisibility? = nil
    var omnibarVisible: Bool? = nil
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
    /// True when the surface is a transparent internal cmux UI (e.g. the diff
    /// viewer). Restored so the surface comes back transparent, not opaque.
    var transparentBackground: Bool? = nil
    /// Diff viewer token + request path, when this browser surface hosts a diff viewer.
    /// Restored by re-registering the token with the app-owned `CmuxDiffViewerURLSchemeHandler`
    /// and navigating via the custom scheme, independent of the (possibly-dead) local HTTP server.
    var diffViewerToken: String? = nil
    var diffViewerRequestPath: String? = nil

    init(
        urlString: String?,
        profileID: UUID?,
        shouldRenderWebView: Bool,
        pageZoom: Double,
        developerToolsVisible: Bool,
        isMuted: Bool = false,
        chromeVisibility: BrowserChromeVisibility? = nil,
        omnibarVisible: Bool? = nil,
        backHistoryURLStrings: [String]?,
        forwardHistoryURLStrings: [String]?,
        transparentBackground: Bool? = nil,
        diffViewerToken: String? = nil,
        diffViewerRequestPath: String? = nil
    ) {
        self.urlString = urlString
        self.profileID = profileID
        self.shouldRenderWebView = shouldRenderWebView
        self.pageZoom = pageZoom
        self.developerToolsVisible = developerToolsVisible
        self.isMuted = isMuted
        self.chromeVisibility = chromeVisibility
        self.omnibarVisible = omnibarVisible
        self.backHistoryURLStrings = backHistoryURLStrings
        self.forwardHistoryURLStrings = forwardHistoryURLStrings
        self.transparentBackground = transparentBackground
        self.diffViewerToken = diffViewerToken
        self.diffViewerRequestPath = diffViewerRequestPath
    }

    private enum CodingKeys: String, CodingKey {
        case urlString
        case profileID
        case shouldRenderWebView
        case pageZoom
        case developerToolsVisible
        case isMuted
        case chromeVisibility
        case omnibarVisible
        case backHistoryURLStrings
        case forwardHistoryURLStrings
        case transparentBackground
        case diffViewerToken
        case diffViewerRequestPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        shouldRenderWebView = try container.decode(Bool.self, forKey: .shouldRenderWebView)
        pageZoom = try container.decode(Double.self, forKey: .pageZoom)
        developerToolsVisible = try container.decode(Bool.self, forKey: .developerToolsVisible)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        chromeVisibility = try container.decodeIfPresent(BrowserChromeVisibility.self, forKey: .chromeVisibility)
        omnibarVisible = try container.decodeIfPresent(Bool.self, forKey: .omnibarVisible)
        backHistoryURLStrings = try container.decodeIfPresent([String].self, forKey: .backHistoryURLStrings)
        forwardHistoryURLStrings = try container.decodeIfPresent([String].self, forKey: .forwardHistoryURLStrings)
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground)
        diffViewerToken = try container.decodeIfPresent(String.self, forKey: .diffViewerToken)
        diffViewerRequestPath = try container.decodeIfPresent(String.self, forKey: .diffViewerRequestPath)
    }
}
struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    var filePath: String
}
struct SessionFilePreviewPanelSnapshot: Codable, Sendable {
    var filePath: String
}
/// Marker for a workspace todo pane; the pane has no content of its own (the checklist
/// persists on the workspace), so the panel `type` plus this empty marker is enough to restore it.
struct SessionWorkspaceTodoPanelSnapshot: Codable, Sendable {}
/// Marker for the global notifications pane; its feed lives in the notification store.
struct SessionNotificationsPanelSnapshot: Codable, Sendable {}
struct SessionProjectPanelSnapshot: Codable, Sendable {
    var projectPath: String
    var selectedNodePath: String?
    var activeTab: String?
    var selectedSchemeName: String?
    var selectedConfigurationName: String?

    init(
        projectPath: String,
        selectedNodePath: String? = nil,
        activeTab: String? = nil,
        selectedSchemeName: String? = nil,
        selectedConfigurationName: String? = nil
    ) {
        self.projectPath = projectPath
        self.selectedNodePath = selectedNodePath
        self.activeTab = activeTab
        self.selectedSchemeName = selectedSchemeName
        self.selectedConfigurationName = selectedConfigurationName
    }
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var stableSurfaceId: UUID? = nil
    var type: PanelType
    var title: String?
    var customTitle: String?
    /// Provenance of `customTitle`; absent provenance restores as user-set for compatibility.
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var directory: String?
    var directoryIsTrustedRemoteReport: Bool? = nil
    var directoryRequiresRemoteTrust: Bool? = nil
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
    var customSidebar: SessionCustomSidebarPanelSnapshot? = nil
    var simulator: SessionSimulatorPanelSnapshot? = nil
    var agentSession: SessionAgentSessionPanelSnapshot? = nil
    var project: SessionProjectPanelSnapshot?
    var workspaceTodo: SessionWorkspaceTodoPanelSnapshot? = nil
    var notificationsPanel: SessionNotificationsPanelSnapshot? = nil
}
extension SessionPanelSnapshot: WorkspaceSessionRemoteRestorePanelSnapshot {}

enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

struct SessionPaneLayoutSnapshot: Codable, Sendable {
    var panelIds: [UUID]
    var selectedPanelId: UUID?
    var isFullWidthTabMode: Bool? = nil
}

struct SessionSplitLayoutSnapshot: Codable, Sendable {
    var orientation: SessionSplitOrientation
    var dividerPosition: Double
    var first: SessionWorkspaceLayoutSnapshot
    var second: SessionWorkspaceLayoutSnapshot
}

indirect enum SessionWorkspaceLayoutSnapshot: Codable, Sendable {
    case pane(SessionPaneLayoutSnapshot)
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionPaneLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported layout node type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

/// One canvas pane's persisted geometry, ordered back-to-front so restore
/// reproduces the z-order.
struct SessionCanvasPaneSnapshot: Codable, Equatable, Sendable {
    /// The pane identity (its founding panel's UUID). Pre-tab snapshots
    /// stored the single hosted panel here.
    var panelId: UUID
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Ordered tabs. Absent in pre-tab snapshots (treated as `[panelId]`).
    var panelIds: [UUID]? = nil
    /// Selected tab. Absent in pre-tab snapshots (treated as `panelId`).
    var selectedPanelId: UUID? = nil
}

/// A cloud machine bound to a workspace through the cmux-tui remote daemon, persisted so a
/// restored `vm:<id>` workspace stays that machine's workspace (`workspace(forCloudVMID:)`,
/// the sidebar cloud button's Base reuse, `vm.terminal_open` targeting). Only the binding is
/// persisted: the pane's link is a process and is not replayed on restore.
struct SessionCloudVMBindingSnapshot: Codable, Sendable, Equatable {
    var vmID: String
    var isBase: Bool
}

struct SessionWorkspaceSnapshot: Codable, Sendable {
    /// Original workspace ID captured when the snapshot comes from a live workspace.
    /// Restore reuses this identity when it is present and non-colliding; legacy,
    /// externally-created, or duplicate snapshots can leave it nil or force a fresh ID.
    var workspaceId: UUID? = nil
    var stableId: UUID? = nil
    var taskCreateOperationID: UUID? = nil
    var processTitle: String
    var customTitle: String?
    /// Provenance of `customTitle`; absent provenance restores as user-set for compatibility.
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var customDescription: String?
    var customColor: String?
    var customizationDirectory: String? = nil
    var usesWorkspaceDirectoryCustomization: Bool? = nil // `nil` infers a legacy local root.
    var isPinned: Bool
    var groupId: UUID? = nil
    var isManuallyUnread: Bool? = nil
    var hasUnreadIndicator: Bool? = nil
    var notifications: [SessionNotificationSnapshot]? = nil
    var terminalScrollBarHidden: Bool?
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    /// `WorkspaceLayoutMode` raw value; absent in pre-canvas snapshots (treated as splits).
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
    /// cmux-tui cloud machine binding; absent in manifests written before the Cloud tree and for
    /// workspaces that are not cloud machines.
    var cloudVM: SessionCloudVMBindingSnapshot? = nil
    /// Remote surfaces this workspace's panes projected (`SurfaceCatalog`); absent for
    /// workspaces that only ever showed local panes, so older manifests decode unchanged.
    var surfaceProjections: [SurfaceProjectionRecord]? = nil
    /// Optional so manifests written before this field decode cleanly.
    var environment: [String: String]? = nil
    /// Manual task-status override raw values and the persisted checklist. Optional-with-nil-default
    /// (the `groupId` back-compat pattern); bridging to/from live `WorkspaceTodoState` lives in `SessionPersistence+Todos.swift`.
    var taskStatusOverride: String? = nil
    var taskStatusInferredAtOverride: String? = nil
    /// `true` when the workspace opted out of the status feature (None); absent for the default (feature engaged), so old manifests decode unchanged.
    var taskStatusHidden: Bool? = nil
    var checklist: [SessionChecklistItemSnapshot]? = nil
    var dock: SessionSplitContainerSnapshot? = nil // Missing legacy fields continue to seed from dock.json.
}
extension SessionWorkspaceSnapshot: WorkspaceSessionRemoteRestoreSnapshot {}

struct SessionWorkspaceGroupSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var isCollapsed: Bool
    /// The group's anchor identity (the group header). For an empty pinned
    /// group this is a stable placeholder rather than a live workspace. The
    /// loader prefers `anchorMemberIndex` (restore-stable) for live groups and
    /// treats this field as a hint when duplicate/corrupt snapshots force a
    /// workspace to mint a fresh UUID.
    var anchorWorkspaceId: UUID? = nil
    /// 0-based index of the anchor among the group's members in tab order. Restore-stable:
    /// tab order is preserved across restore, so the same index resolves to the same
    /// logical anchor even when a workspace UUID cannot be reused. Older snapshots
    /// that omit this field fall back to "first member by tab order".
    var anchorMemberIndex: Int? = nil
    /// `true` when the group intentionally has no live workspace anchor.
    /// Optional for snapshots written before pinned empty groups were supported.
    var anchorIsEmpty: Bool? = nil
    var isPinned: Bool? = nil
    var customColor: String? = nil
    var iconSymbol: String? = nil
}

extension SessionWorkspaceSnapshot {
    var hasRestorablePanels: Bool {
        !panels.isEmpty || dock != nil
    }
}

extension SessionWindowSnapshot {
    var hasRestorablePanels: Bool {
        dock != nil || tabManager.workspaces.contains { $0.hasRestorablePanels }
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
    /// Per-display-configuration remembered frames (LRU ring). Optional and
    /// additive so older persisted snapshots decode unchanged.
    var configFrames: [SessionConfigFrameEntry]? = nil
    var dock: SessionSplitContainerSnapshot? = nil // Missing legacy fields continue to seed from dock.json.
}
struct AppSessionSnapshot: Codable, Sendable {
    var version: Int
    var createdAt: TimeInterval
    var windows: [SessionWindowSnapshot]
}

extension AppSessionSnapshot: SessionSnapshotRepresenting {
    /// Whether the snapshot carries at least one window. The `CmuxSession` repository
    /// treats an empty-window snapshot as unusable (empty states remove the file instead
    /// of writing it), matching the legacy `!snapshot.windows.isEmpty` usability check.
    var hasWindows: Bool { !windows.isEmpty }
}

enum SessionScrollbackReplayStore {
    static let environmentKey = "CMUX_RESTORE_SCROLLBACK_FILE"
    static let boundaryPrefix = "/.cmux/session-scrollback-replay/"
    private static let directoryName = "cmux-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"
    nonisolated static func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        replayEnvironment(forFileURL: replayFileURL(for: scrollback, tempDirectory: tempDirectory))
    }
    nonisolated static func replayFileURL(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        guard let replayText = normalizedScrollback(scrollback) else { return nil }
        return writeReplayFile(contents: replayText, tempDirectory: tempDirectory)
    }
    nonisolated static func replayEnvironment(forFileURL replayFileURL: URL?) -> [String: String] {
        guard let replayFileURL else { return [:] }
        return [environmentKey: replayFileURL.path]
    }
    nonisolated static func startBoundaryValue(forReplayFilePath path: String) -> String {
        boundaryPrefix + URL(fileURLWithPath: path).lastPathComponent + "/start"
    }
    nonisolated static func endBoundaryValue(forReplayFilePath path: String) -> String {
        boundaryPrefix + URL(fileURLWithPath: path).lastPathComponent + "/end"
    }
    nonisolated private static func normalizedScrollback(_ scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        // Restored history must not reconfigure the live terminal's colors: the active theme
        // owns the default foreground/background (and palette), so default-colored cells track
        // it. The captured scrollback bakes the capture-time theme via terminal-color OSC
        // sequences (e.g. OSC 10/11), which would otherwise survive a theme change as
        // white-on-white output (issue #5165). Strip them before replay.
        let themePortable = strippingTerminalColorOSCSequences(scrollback)
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(themePortable) else { return nil }
        return ansiSafeReplayText(truncated)
    }
    /// Preserve ANSI color state safely across replay boundaries.
    nonisolated private static func ansiSafeReplayText(_ text: String) -> String {
        guard text.contains(ansiEscape) else { return text }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return output
    }
    /// Removes terminal-color OSC sequences (palette entries and the dynamic
    /// foreground/background/cursor/highlight colors plus their resets) from captured
    /// scrollback so the restored history does not reconfigure the live terminal's colors.
    /// Ghostty's `write_screen_file:copy,vt` export bakes the capture-time theme by
    /// prepending `OSC 10` / `OSC 11` (and resolving palette entries). Replaying those into
    /// a freshly launched terminal would override the active theme's default colors, so
    /// restored default-colored cells would keep the old theme (white-on-white after a theme
    /// change — issue #5165). Explicit per-cell SGR colors and every non-color escape
    /// sequence (titles, hyperlinks, prompt marks, …) are preserved verbatim.
    nonisolated private static func strippingTerminalColorOSCSequences(_ text: String) -> String {
        let escByte: UInt8 = 0x1B
        let oscIntroducer: UInt8 = 0x5D // ]
        let bel: UInt8 = 0x07
        let backslash: UInt8 = 0x5C
        let zero: UInt8 = 0x30
        let nine: UInt8 = 0x39
        let bytes = Array(text.utf8)
        guard bytes.contains(escByte) else { return text }
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        let count = bytes.count
        var index = 0
        while index < count {
            let byte = bytes[index]
            guard byte == escByte,
                  index + 1 < count,
                  bytes[index + 1] == oscIntroducer else {
                output.append(byte)
                index += 1
                continue
            }
            // Parse the OSC numeric command (Ps) following `ESC ]`.
            var cursor = index + 2
            var code = 0
            var sawDigit = false
            while cursor < count, bytes[cursor] >= zero, bytes[cursor] <= nine {
                code = (code * 10) + Int(bytes[cursor] - zero)
                sawDigit = true
                cursor += 1
                if code > 100_000 { break } // overflow guard for malformed input
            }
            guard sawDigit, isTerminalColorOSCCode(code) else {
                // Not a terminal-color OSC; emit `ESC` and resume scanning so the
                // rest of the preserved sequence is copied verbatim.
                output.append(byte)
                index += 1
                continue
            }
            // Consume through the OSC terminator (BEL or `ESC \` / ST). A truncated
            // (unterminated) color OSC at the end of the buffer is dropped as well.
            var end = cursor
            var terminated = false
            while end < count {
                if bytes[end] == bel {
                    end += 1
                    terminated = true
                    break
                }
                if bytes[end] == escByte, end + 1 < count, bytes[end + 1] == backslash {
                    end += 2
                    terminated = true
                    break
                }
                end += 1
            }
            index = terminated ? end : count
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Returns `true` for OSC command numbers that configure terminal colors
    /// (palette entries and the dynamic foreground/background/cursor/highlight
    /// colors plus their resets), which restored scrollback must not carry.
    nonisolated private static func isTerminalColorOSCCode(_ code: Int) -> Bool {
        switch code {
        case 4, 5, 104, 105: return true // palette / special color set + reset
        case 10...19: return true        // dynamic colors (fg, bg, cursor, …)
        case 110...119: return true      // dynamic color resets
        default: return false
        }
    }
    nonisolated private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let directory = tempDirectory.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("txt")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}
