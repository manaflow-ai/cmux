import CoreGraphics
import Foundation
import Bonsplit
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Surface resume binding snapshot and launcher scripts
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
        return TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
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
        let quotedCommand = TerminalStartupShellQuoting.singleQuoted(command)
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
            let quotedDirectory = TerminalStartupShellQuoting.singleQuoted(workingDirectory)
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

