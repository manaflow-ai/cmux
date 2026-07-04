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

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance
    /// to the first printable character after that sequence to avoid replaying
    /// malformed control bytes.
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

struct SessionDisplaySnapshot: Codable, Sendable {
    var displayID: UInt32?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    case tabs
    case notifications

    init(selection: SidebarSelection) {
        switch selection {
        case .tabs:
            self = .tabs
        case .notifications:
            self = .notifications
        }
    }

    var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            return .notifications
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
        let normalizedKind = Self.normalized(kind)
        let normalizedSource = Self.normalized(source)
        self.name = Self.normalized(name)
        self.kind = normalizedKind
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

    func retargetingWorkingDirectory(_ workingDirectory: String?) -> SurfaceResumeBindingSnapshot {
        guard isAgentHookBinding else { return self }
        let normalizedCwd = Self.normalized(workingDirectory)
        let retargetedCommand = TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: command,
            previousWorkingDirectory: cwd,
            workingDirectory: normalizedCwd
        )
        return SurfaceResumeBindingSnapshot(
            name: name,
            kind: kind,
            command: retargetedCommand,
            cwd: normalizedCwd,
            checkpointId: checkpointId,
            source: source,
            environment: environment,
            autoResume: autoResume,
            approvalPolicy: approvalPolicy,
            approvalRecordId: approvalRecordId,
            updatedAt: updatedAt
        )
    }

    static let maxInlineStartupInputBytes = SessionRestorableAgentSnapshot.maxInlineStartupInputBytes

    var startupInput: String? {
        inlineStartupInput
    }

    var inlineStartupInput: String? {
        inlineStartupInput(repairPortableAgentExecutable: true)
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

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SurfaceResumeBindingSnapshot: WorkspaceSurfaceResumeBinding {
    var requiresPromptApproval: Bool {
        approvalPolicy == .prompt
    }
}

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

enum SurfaceResumeApprovalStore {
    static let didChangeNotification = Notification.Name("cmux.surfaceResumeApprovalsDidChange")
    private static let legacyFileName = "resume-commands.json"
    private static let secretFileName = ".surface-resume-approval-secret"
    private static let settingsTerminalSectionKey = "terminal"
    private static let settingsRecordsKey = "resumeCommands"
    private static let keychainService = "com.cmuxterm.app.surface-resume-approvals"
    private static let keychainAccount = "hmac-secret-v1"

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

    static func validRecords(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> [SurfaceResumeApprovalRecord] {
        let signingSecret = signingSecret ?? defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret else { return [] }
        return loadRecords(fileURL: fileURL, fileManager: fileManager)
            .filter { $0.hasValidSignature(secret: signingSecret) }
    }

    static func matchingRecord(
        for binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalRecord? {
        validRecords(fileURL: fileURL, fileManager: fileManager, signingSecret: signingSecret)
            .filter { $0.matches(binding) }
            .sorted { lhs, rhs in
                if lhs.commandPrefix.count != rhs.commandPrefix.count {
                    return lhs.commandPrefix.count > rhs.commandPrefix.count
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    static func applyingStoredApproval(
        to binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeBindingSnapshot {
        if binding.isProcessDetected {
            var trustedBinding = binding
            trustedBinding.autoResume = true
            trustedBinding.approvalPolicy = .auto
            trustedBinding.approvalRecordId = nil
            return trustedBinding
        }

        if binding.isAgentHookBinding {
            var trustedBinding = binding
            trustedBinding.autoResume = binding.autoResume == true
            trustedBinding.approvalPolicy = trustedBinding.autoResume == true ? .auto : .manual
            trustedBinding.approvalRecordId = nil
            return trustedBinding
        }

        var effective = binding
        guard let record = matchingRecord(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        ) else {
            effective.autoResume = false
            effective.approvalPolicy = .manual
            effective.approvalRecordId = nil
            return effective
        }

        effective.approvalPolicy = record.policy
        effective.approvalRecordId = record.id
        effective.autoResume = record.policy == .auto
        return effective
    }

    static func shouldPromptForProposal(
        binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?,
        isMainThread: Bool,
        isRunningTests: Bool
    ) -> Bool {
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
        guard SurfaceResumeCommandCanonicalizer.tokens(from: binding.command) != nil else {
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
        var effectiveBinding = applyingStoredApproval(
            to: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        )
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
        let signingSecret = signingSecret ?? defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret,
              let tokens = SurfaceResumeCommandCanonicalizer.tokens(from: binding.command) else {
            return nil
        }
        let prefix = commandPrefix ?? tokens
        guard !prefix.isEmpty, tokens.count >= prefix.count, Array(tokens.prefix(prefix.count)) == prefix else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        let existing = matchingRecord(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        )
        let record = SurfaceResumeApprovalRecord(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            name: binding.name,
            commandPrefix: prefix,
            cwd: binding.cwd,
            environment: binding.environment,
            environmentKeys: Array((binding.environment ?? [:]).keys),
            source: binding.source,
            policy: policy,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            lastUsedAt: existing?.lastUsedAt,
            signature: nil
        ).signed(secret: signingSecret)
        writeReplacing(record: record, fileURL: fileURL, fileManager: fileManager)
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
        let signingSecret = signingSecret ?? defaultSigningSecret(fileManager: fileManager)
        guard let signingSecret else { return false }
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

    static func isValid(_ record: SurfaceResumeApprovalRecord, signingSecret: Data? = defaultSigningSecret()) -> Bool {
        guard let signingSecret else { return false }
        return record.hasValidSignature(secret: signingSecret)
    }

    static func defaultSigningSecret(fileManager: FileManager = .default) -> Data? {
        let env = ProcessInfo.processInfo.environment
        if let encoded = env["CMUX_SURFACE_RESUME_APPROVAL_SECRET_B64"],
           let data = Data(base64Encoded: encoded),
           !data.isEmpty {
            return data
        }
        if let data = keychainSecret(), !data.isEmpty {
            return data
        }
        let generated = randomSecret()
        if storeKeychainSecret(generated) {
            return generated
        }
        return fileBackedSecret(fileManager: fileManager, generated: generated)
    }

    private static func writeReplacing(
        record: SurfaceResumeApprovalRecord,
        fileURL: URL,
        fileManager: FileManager
    ) {
        var records = loadRecords(fileURL: fileURL, fileManager: fileManager)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        _ = write(records: records, fileURL: fileURL, fileManager: fileManager)
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

nonisolated enum TerminalStartupReturnShellScript {
    private static let shellLine = #"_cmux_resume_shell="${SHELL:-/bin/zsh}""#
    private static let zshIntegrationReentryLines = [
        #"if [[ "${_cmux_resume_shell:t}" == "zsh" ]]; then"#,
        #"  _cmux_resume_zdotdir_is_integration() { [[ -n "${1:-}" && ( "$1" == "${CMUX_SHELL_INTEGRATION_DIR:-}" || "$1" == */Contents/Resources/shell-integration ) ]]; }"#,
        #"  if [[ -n "${CMUX_SHELL_INTEGRATION_DIR:-}" && -r "${CMUX_SHELL_INTEGRATION_DIR}/.zshenv" ]]; then"#,
        #"    if [[ -n "${ZDOTDIR+X}" ]] && ! _cmux_resume_zdotdir_is_integration "$ZDOTDIR"; then export CMUX_ZSH_ZDOTDIR="$ZDOTDIR"; elif [[ -n "${CMUX_ZSH_ZDOTDIR+X}" ]] && _cmux_resume_zdotdir_is_integration "$CMUX_ZSH_ZDOTDIR"; then unset CMUX_ZSH_ZDOTDIR; fi; export ZDOTDIR="$CMUX_SHELL_INTEGRATION_DIR""#,
        #"  else"#,
        #"    if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"; unset GHOSTTY_ZSH_ZDOTDIR; elif [[ -n "${CMUX_ZSH_ZDOTDIR+X}" ]] && ! _cmux_resume_zdotdir_is_integration "$CMUX_ZSH_ZDOTDIR"; then export ZDOTDIR="$CMUX_ZSH_ZDOTDIR"; unset CMUX_ZSH_ZDOTDIR; elif [[ -n "${ZDOTDIR+X}" ]] && _cmux_resume_zdotdir_is_integration "$ZDOTDIR"; then unset ZDOTDIR; unset CMUX_ZSH_ZDOTDIR; fi"#,
        #"  fi; unfunction _cmux_resume_zdotdir_is_integration 2>/dev/null || true"#,
        #"fi"#,
    ]

    static func commandThenReturnLines(command: String, workingDirectory: String? = nil) -> [String] {
        let quotedCommand = TerminalStartupShellQuoting.singleQuoted(command)
        var lines = [shellLine] + zshIntegrationReentryLines + [
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
            let quotedDirectory = TerminalStartupShellQuoting.singleQuoted(workingDirectory)
            lines.append(#"{ cd -- \#(quotedDirectory) 2>/dev/null || true; }"#)
        }
        lines.append(#"exec -l "$_cmux_resume_shell""#)
        return lines
    }
}

enum SurfaceResumeBindingScriptStore {
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
    var omnibarVisible: Bool? = nil
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
    /// True when the surface is a transparent internal cmux UI (e.g. the diff
    /// viewer). Restored so the surface comes back transparent, not opaque.
    var transparentBackground: Bool? = nil
    /// Diff viewer token + request path, when this browser surface hosts a diff
    /// viewer. Restored by re-registering the token with the app-owned
    /// `CmuxDiffViewerURLSchemeHandler` and navigating via the custom scheme,
    /// independent of the (possibly-dead) local HTTP server.
    var diffViewerToken: String? = nil
    var diffViewerRequestPath: String? = nil

    init(
        urlString: String?,
        profileID: UUID?,
        shouldRenderWebView: Bool,
        pageZoom: Double,
        developerToolsVisible: Bool,
        isMuted: Bool = false,
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
struct SessionCustomSidebarPanelSnapshot: Codable, Sendable { var name: String }
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
    var customSidebar: SessionCustomSidebarPanelSnapshot? = nil
    var agentSession: SessionAgentSessionPanelSnapshot? = nil
    var project: SessionProjectPanelSnapshot?
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

struct SessionWorkspaceGroupSnapshot: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var isCollapsed: Bool
    /// The workspace whose close dissolves the group. Only meaningful within
    /// a single app run; on restore, each workspace gets a fresh UUID. The
    /// loader prefers `anchorMemberIndex` (restore-stable) and treats this
    /// field as a hint for in-process round-trips.
    var anchorWorkspaceId: UUID? = nil
    /// 0-based index of the anchor among the group's members in tab order.
    /// Restore-stable: tab order is preserved across restore, so the same
    /// index resolves to the same logical anchor even though workspace UUIDs
    /// change. Older snapshots that omit this field fall back to "first
    /// member by tab order".
    var anchorMemberIndex: Int? = nil
    var isPinned: Bool? = nil
    var customColor: String? = nil
    var iconSymbol: String? = nil
}

extension SessionWorkspaceSnapshot {
    var hasRestorablePanels: Bool {
        !panels.isEmpty
    }
}

extension SessionWindowSnapshot {
    var hasRestorablePanels: Bool {
        tabManager.workspaces.contains { $0.hasRestorablePanels }
    }

    /// Whether this window carries anything to restore. A window with no
    /// workspaces (tabs) is a "phantom"/"empty shell": it renders no content,
    /// yet restore still creates a real NSWindow + GPU surface for it. Such
    /// windows are persisted across an unclean shutdown and replaying them on
    /// launch can wedge the WindowServer and freeze the desktop (issue #6646).
    /// A window with at least one workspace is restorable even when that
    /// workspace has no panels yet — the workspace may be a pinned/titled tab
    /// the user wants to keep — so the phantom test is "no tabs", matching the
    /// existing empty-workspace skip for dedicated remote windows.
    var hasRestorableTabs: Bool {
        !tabManager.workspaces.isEmpty
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
    /// A copy of the snapshot with phantom ("empty shell") windows removed, or
    /// `nil` when no restorable window remains. A phantom window has no tabs
    /// (`hasRestorableTabs == false`). The `SessionSnapshotRepository` discards
    /// these on load and treats an all-phantom snapshot as unusable — empty
    /// states remove the file instead of writing it — so a session corrupted by
    /// an unclean shutdown never replays its phantoms into a WindowServer hang
    /// (issue #6646). An all-restorable snapshot returns `self` unchanged so the
    /// on-disk bytes are byte-for-byte stable.
    var discardingNonRestorableWindows: AppSessionSnapshot? {
        let restorableWindows = windows.filter { $0.hasRestorableTabs }
        guard !restorableWindows.isEmpty else { return nil }
        guard restorableWindows.count != windows.count else { return self }
        var copy = self
        copy.windows = restorableWindows
        return copy
    }
}

enum SessionScrollbackReplayStore {
    static let environmentKey = "CMUX_RESTORE_SCROLLBACK_FILE"
    private static let directoryName = "cmux-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    static func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        guard let replayText = normalizedScrollback(scrollback) else { return [:] }
        guard let replayFileURL = writeReplayFile(
            contents: replayText,
            tempDirectory: tempDirectory
        ) else {
            return [:]
        }
        return [environmentKey: replayFileURL.path]
    }

    private static func normalizedScrollback(_ scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        // Restored history must not reconfigure the live terminal's colors: the
        // active theme owns the default foreground/background (and palette), so
        // default-colored cells track it. The captured scrollback bakes the
        // capture-time theme via terminal-color OSC sequences (e.g. OSC 10/11),
        // which would otherwise survive a theme change as white-on-white output
        // (issue #5165). Strip them before replay.
        let themePortable = strippingTerminalColorOSCSequences(scrollback)
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(themePortable) else { return nil }
        return ansiSafeReplayText(truncated)
    }

    /// Preserve ANSI color state safely across replay boundaries.
    private static func ansiSafeReplayText(_ text: String) -> String {
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
    /// foreground/background/cursor/highlight colors plus their resets) from
    /// captured scrollback so the restored history does not reconfigure the live
    /// terminal's colors.
    ///
    /// Ghostty's `write_screen_file:copy,vt` export bakes the capture-time theme
    /// by prepending `OSC 10` / `OSC 11` (and resolving palette entries). Replaying
    /// those into a freshly launched terminal would override the active theme's
    /// default colors, so restored default-colored cells would keep the old theme
    /// (white-on-white after a theme change — issue #5165). Explicit per-cell SGR
    /// colors and every non-color escape sequence (titles, hyperlinks, prompt
    /// marks, …) are preserved verbatim.
    private static func strippingTerminalColorOSCSequences(_ text: String) -> String {
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
    private static func isTerminalColorOSCCode(_ code: Int) -> Bool {
        switch code {
        case 4, 5, 104, 105: return true // palette / special color set + reset
        case 10...19: return true        // dynamic colors (fg, bg, cursor, …)
        case 110...119: return true      // dynamic color resets
        default: return false
        }
    }

    private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
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
