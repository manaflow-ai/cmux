import Foundation
import CMUXAgentLaunch
import CmuxFoundation

// MARK: - Resume/fork command assembly forwarder

/// Maps the app-side agent domain types onto the pure
/// ``CMUXAgentLaunch/AgentResumeCommandBuilder`` value inputs.
///
/// The resume/fork command assembly itself lives in `CMUXAgentLaunch` as a
/// stateless value type. The app retains these thin forwarders because the
/// builder's callers speak the app-only `RestorableAgentKind`,
/// `AgentLaunchCommandSnapshot`, and `CmuxVaultAgentRegistration` types, which
/// cannot move into the package (the kind enum and the registry struct are
/// app-owned). Each forwarder lowers its app type to the matching package value
/// (`AgentResumeKindDescriptor`/`AgentResumeLaunchCommand`/`AgentResumeRegistrationOverride`)
/// and delegates to a freshly constructed builder.
extension RestorableAgentKind {
    /// This kind lowered to the package's resume-builder descriptor.
    var resumeKindDescriptor: AgentResumeKindDescriptor {
        AgentResumeKindDescriptor(
            rawValue: rawValue,
            isClaude: self == .claude,
            isCustom: customAgentID != nil
        )
    }
}

extension AgentLaunchCommandSnapshot {
    /// This snapshot lowered to the package's resume-builder launch command,
    /// dropping the persistence-only `capturedAt`/`source` fields the builder
    /// never reads.
    var resumeLaunchCommand: AgentResumeLaunchCommand {
        AgentResumeLaunchCommand(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }
}

extension CmuxVaultAgentRegistration {
    /// This registration lowered to the package's resume-builder override,
    /// flagging the built-in antigravity agent (resumed via `--conversation`).
    var resumeRegistrationOverride: AgentResumeRegistrationOverride {
        AgentResumeRegistrationOverride(
            resumeCommand: resumeCommand,
            forkCommand: forkCommand,
            cwd: cwd == .ignore ? .ignore : .preserve,
            sessionDirectory: sessionDirectory,
            defaultExecutable: defaultExecutable,
            isAntigravity: id == CmuxVaultAgentRegistration.builtInAntigravity.id
        )
    }
}

extension AgentResumeCommandBuilder {
    /// Forwards to ``resumeShellCommand(kind:sessionId:launchCommand:workingDirectory:registrationOverride:includeWorkingDirectoryPrefix:)``
    /// with the app domain types lowered to package values.
    static func resumeShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        AgentResumeCommandBuilder().resumeShellCommand(
            kind: kind.resumeKindDescriptor,
            sessionId: sessionId,
            launchCommand: launchCommand?.resumeLaunchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registrationOverride?.resumeRegistrationOverride,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    /// Forwards to ``forkShellCommand(kind:sessionId:launchCommand:workingDirectory:registrationOverride:includeWorkingDirectoryPrefix:)``
    /// with the app domain types lowered to package values.
    static func forkShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        AgentResumeCommandBuilder().forkShellCommand(
            kind: kind.resumeKindDescriptor,
            sessionId: sessionId,
            launchCommand: launchCommand?.resumeLaunchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registrationOverride?.resumeRegistrationOverride,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    /// Forwards to ``openCodeVersionProbe(launchCommand:)`` with the app
    /// snapshot lowered to a package launch command.
    static func openCodeVersionProbe(
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> (executable: String, arguments: [String])? {
        AgentResumeCommandBuilder().openCodeVersionProbe(
            launchCommand: launchCommand?.resumeLaunchCommand
        )
    }
}

struct SessionRestorableAgentSnapshot: Codable, Sendable {
    static let maxInlineStartupInputBytes = 900

    var kind: RestorableAgentKind
    var sessionId: String
    var workingDirectory: String?
    var launchCommand: AgentLaunchCommandSnapshot?
    var registration: CmuxVaultAgentRegistration? = nil

    var resumeCommand: String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    var forkCommand: String? {
        AgentResumeCommandBuilder.forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    func resumeStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true,
        allowOversizedInlineInput: Bool = false
    ) -> String? {
        startupInput(
            command: resumeCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript,
            allowOversizedInlineInput: allowOversizedInlineInput
        )
    }

    func resumeStartupCommand(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        // Match the resume command's own cd: agents with an `.ignore` cwd policy resume from
        // the current directory (no cd), so the post-exit shell must not force the launch dir.
        let returnShellWorkingDirectory = registration?.cwd == .ignore
            ? nil
            : (workingDirectory ?? launchCommand?.workingDirectory)
        guard let command = resumeCommand,
              let scriptURL = AgentResumeScriptStore(
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory
              ).writeLauncherScript(
                  command: command,
                  kindRawValue: kind.rawValue,
                  sessionId: sessionId,
                  returnShellLines: TerminalStartupReturnShellScript.commandThenReturnLines(
                      command: command,
                      workingDirectory: returnShellWorkingDirectory
                  )
              ) else {
            return nil
        }
        return "/bin/zsh \(scriptURL.path.posixShellQuoted)"
    }

    func forkStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true
    ) -> String? {
        startupInput(
            command: forkCommand,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            allowLauncherScript: allowLauncherScript
        )
    }

    private func startupInput(
        command: String?,
        fileManager: FileManager,
        temporaryDirectory: URL,
        allowLauncherScript: Bool = true,
        allowOversizedInlineInput: Bool = false
    ) -> String? {
        guard let command else { return nil }
        let inlineInput = command + "\n"
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard !allowOversizedInlineInput else {
            return inlineInput
        }
        guard allowLauncherScript else { return nil }
        guard let scriptURL = AgentResumeScriptStore(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ).writeLauncherScript(
            command: command,
            kindRawValue: kind.rawValue,
            sessionId: sessionId
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(scriptURL.path.posixShellQuoted)\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }
}

extension SessionRestorableAgentSnapshot {
    var agentDisplayName: String {
        if let name = registration?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return kind.displayName
    }
}

private struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentLaunchCommandSnapshot?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    var updatedAt: TimeInterval
}

extension RestorableAgentHookSessionRecord {
    /// This record lowered to the package-side ``CMUXAgentLaunch/ClaudeTranscriptRecordInput``,
    /// carrying only the String/optional fields the transcript resolver reads
    /// (so the package never imports this app-private record type).
    var claudeTranscriptInput: ClaudeTranscriptRecordInput {
        ClaudeTranscriptRecordInput(
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: transcriptPath,
            launchWorkingDirectory: launchCommand?.workingDirectory,
            claudeConfigDirectory: launchCommand?.environment?["CLAUDE_CONFIG_DIR"]
        )
    }
}

private struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(entriesByPanel: [:])

    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    struct Entry: Sendable {
        let snapshot: SessionRestorableAgentSnapshot
        let lifecycle: AgentHibernationLifecycleState?
        let updatedAt: TimeInterval
        let processIDs: Set<Int>
    }

    /// App-side spelling of the lifted ``CMUXAgentLaunch/ProcessDetectedSessionIDSource``,
    /// kept so existing `RestorableAgentSessionIndex.ProcessDetectedSessionIDSource`
    /// references continue to resolve after the enum moved into `CMUXAgentLaunch`.
    typealias ProcessDetectedSessionIDSource = CMUXAgentLaunch.ProcessDetectedSessionIDSource

    typealias ProcessDetectedSnapshotEntry = (
        snapshot: SessionRestorableAgentSnapshot,
        updatedAt: TimeInterval,
        processIDs: Set<Int>,
        sessionIDSource: ProcessDetectedSessionIDSource
    )

    private struct SessionKey: Hashable {
        let kind: RestorableAgentKind
        let sessionId: String
    }

    private struct PanelKindKey: Hashable {
        let panelKey: PanelKey
        let kind: RestorableAgentKind
    }

    private let entriesByPanel: [PanelKey: Entry]
    private let entriesByPanelId: [UUID: Entry]

    private func entry(workspaceId: UUID, panelId: UUID) -> Entry? {
        entriesByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? entriesByPanelId[panelId]
    }

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        entry(workspaceId: workspaceId, panelId: panelId)?.snapshot
    }

    func lifecycle(workspaceId: UUID, panelId: UUID) -> AgentHibernationLifecycleState? {
        entry(workspaceId: workspaceId, panelId: panelId)?.lifecycle
    }

    func updatedAt(workspaceId: UUID, panelId: UUID) -> TimeInterval? {
        entry(workspaceId: workspaceId, panelId: panelId)?.updatedAt
    }

    func processIDs(workspaceId: UUID, panelId: UUID) -> Set<Int> {
        entry(workspaceId: workspaceId, panelId: panelId)?.processIDs ?? []
    }

    func hasLiveProcess(workspaceId: UUID, panelId: UUID) -> Bool {
        !processIDs(workspaceId: workspaceId, panelId: panelId).isEmpty
    }

    // WARNING: Expensive. This reads every agent kind's hook-store file from disk,
    // resolves transcripts, and runs sysctl(KERN_PROCARGS2) per recorded session for
    // live-PID filtering (measured 350ms-1.8s on machines with large agent history).
    // NEVER call it synchronously on the main actor or in interactive paths (workspace/
    // panel/window close, SwiftUI body, didSet, menu evaluation, socket handlers). Read
    // the off-main, cached `SharedLiveAgentIndex` instead (the app-owned instance vended
    // by `hostEnvironment.sharedLiveAgentIndex`; the singleton was de-singletonized). The
    // only sanctioned synchronous callers are cold-cache fallbacks guarded by a nil cache check.
    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: [:]
        )
    }

    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            loadIncludingProcessDetectedSnapshotsSynchronously(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        }.value
    }

    static func loadIncludingProcessDetectedSnapshotsSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager
        )
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
    }

    static func load(
        homeDirectory: String,
        fileManager: FileManager,
        registry: CmuxVaultAgentRegistry,
        detectedSnapshots: [PanelKey: ProcessDetectedSnapshotEntry],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: Entry] = [:]
        let claudeTranscriptStore = ClaudeTranscriptStore(
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
        let builtInKindIDs = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let hookKinds: [(kind: RestorableAgentKind, registration: CmuxVaultAgentRegistration?)] =
            RestorableAgentKind.allCases.map { (kind: $0, registration: nil) }
            + registry.registrations.compactMap { registration in
                builtInKindIDs.contains(registration.id)
                    ? nil
                    : (kind: .custom(registration.id), registration: registration)
            }
        var hookCandidatesBySession: [SessionKey: Entry] = [:]
        var hookCandidatesByPanelAndKind: [PanelKindKey: Entry] = [:]

        for (kind, registration) in hookKinds {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                var effectiveRecord = kind == .claude
                    ? resolvedClaudeWorkflowRecord(record, store: claudeTranscriptStore)
                    : record
                // Drop untrusted launch captures before ANY derivation: the
                // working directory below would otherwise inherit the foreign
                // agent's launch cwd even though the launch command is stripped.
                effectiveRecord.launchCommand = trustedLaunchCommand(
                    effectiveRecord.launchCommand,
                    kind: kind
                )
                let normalizedSessionId = effectiveRecord.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: effectiveRecord.workspaceId),
                      let panelId = UUID(uuidString: effectiveRecord.surfaceId),
                      hookRecordIsRestorable(
                          effectiveRecord,
                          kind: kind,
                          fileManager: fileManager,
                          claudeTranscriptStore: claudeTranscriptStore
                      ) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: restorableWorkingDirectory(
                        for: effectiveRecord,
                        kind: kind,
                        registration: registration,
                        claudeTranscriptStore: claudeTranscriptStore
                    ),
                    launchCommand: effectiveRecord.launchCommand,
                    registration: registration
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                let sessionKey = SessionKey(kind: kind, sessionId: normalizedSessionId)
                let panelKindKey = PanelKindKey(panelKey: key, kind: kind)
                let liveProcessID = liveScopedProcessID(
                    for: effectiveRecord,
                    kind: kind,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    processArgumentsProvider: processArgumentsProvider
                )
                let entry = Entry(
                    snapshot: snapshot,
                    lifecycle: effectiveRecord.agentLifecycle,
                    updatedAt: effectiveRecord.updatedAt,
                    processIDs: liveProcessID.map { [$0] } ?? []
                )
                let previousPanelKindUpdatedAt =
                    hookCandidatesByPanelAndKind[panelKindKey]?.updatedAt ?? -Double.infinity
                if previousPanelKindUpdatedAt <= effectiveRecord.updatedAt {
                    hookCandidatesByPanelAndKind[panelKindKey] = entry
                }
                if hookCandidatesBySession[sessionKey]?.updatedAt ?? -Double.infinity <= effectiveRecord.updatedAt {
                    hookCandidatesBySession[sessionKey] = entry
                }
                guard effectiveRecord.pid == nil || liveProcessID != nil else {
                    continue
                }
                if let existing = resolved[key], existing.updatedAt > effectiveRecord.updatedAt {
                    continue
                }
                resolved[key] = entry
            }
        }

        for (key, detected) in detectedSnapshots {
            let sameKindPanelCandidate = hookCandidatesByPanelAndKind[
                PanelKindKey(panelKey: key, kind: detected.snapshot.kind)
            ]
            if let existing = Self.matchingHookEntry(
                for: detected.snapshot,
                resolved: resolved[key],
                panelCandidate: sameKindPanelCandidate,
                sessionCandidate: hookCandidatesBySession[
                    SessionKey(kind: detected.snapshot.kind, sessionId: detected.snapshot.sessionId)
                ]
            ) {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: existing.lifecycle,
                    updatedAt: existing.updatedAt,
                    processIDs: detected.processIDs
                )
            } else if detected.sessionIDSource == .inferredLatestSessionFile,
                      let panelCandidate = sameKindPanelCandidate {
                // Latest-file detection is ambiguous when multiple panels share a cwd; preserve the exact
                // hook-store identity while still carrying live process evidence for this panel.
                resolved[key] = Entry(
                    snapshot: panelCandidate.snapshot,
                    lifecycle: panelCandidate.lifecycle,
                    updatedAt: panelCandidate.updatedAt,
                    processIDs: detected.processIDs
                )
            } else {
                resolved[key] = Entry(
                    snapshot: detected.snapshot,
                    lifecycle: nil,
                    updatedAt: 0,
                    processIDs: detected.processIDs
                )
            }
        }

        return RestorableAgentSessionIndex(entriesByPanel: resolved)
    }

    private static func matchingHookEntry(
        for snapshot: SessionRestorableAgentSnapshot,
        resolved: Entry?,
        panelCandidate: Entry?,
        sessionCandidate: Entry?
    ) -> Entry? {
        [resolved, panelCandidate, sessionCandidate].compactMap { $0 }
            .filter {
                $0.snapshot.kind == snapshot.kind &&
                    $0.snapshot.sessionId == snapshot.sessionId
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        normalizedNonEmptyValue(rawValue)
    }

    /// Drops launch captures that cannot describe this agent kind: a capture
    /// inherited from a different agent's session (codex started under claude
    /// carries claude's `CMUX_AGENT_LAUNCH_*`) or the hook dispatch shell's own
    /// argv. Resume/fork then fall back to the kind's bare verbs instead of
    /// rendering the foreign binary. Existing poisoned records heal on load.
    private static func trustedLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?,
        kind: RestorableAgentKind
    ) -> AgentLaunchCommandSnapshot? {
        guard let launchCommand else { return nil }
        guard AgentLaunchCaptureTrust.launcherDescribesKind(launchCommand.launcher, kind: kind.rawValue),
              !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(launchCommand.arguments) else {
            return nil
        }
        return launchCommand
    }

    /// Whether the hook record describes a session cmux can restore.
    ///
    /// Non-Claude kinds restore on their `isRestorable` flag. Claude restores when
    /// the recorded transcript exists, or when the ``CMUXAgentLaunch/ClaudeTranscriptStore``
    /// can locate the session's `.jsonl` under a config root.
    private static func hookRecordIsRestorable(
        _ record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        fileManager: FileManager,
        claudeTranscriptStore: ClaudeTranscriptStore
    ) -> Bool {
        guard kind == .claude else {
            return record.isRestorable != false
        }
        return claudeTranscriptStore.claudeTranscriptExists(for: record.claudeTranscriptInput)
    }

    /// Re-resolves a stale Claude workflow record's session id + transcript path
    /// via the package store, returning the original record unchanged when the
    /// store finds no newer sibling transcript.
    private static func resolvedClaudeWorkflowRecord(
        _ record: RestorableAgentHookSessionRecord,
        store: ClaudeTranscriptStore
    ) -> RestorableAgentHookSessionRecord {
        guard let resolved = store.resolvedClaudeWorkflow(for: record.claudeTranscriptInput) else {
            return record
        }
        var resolvedRecord = record
        resolvedRecord.sessionId = resolved.sessionId
        resolvedRecord.transcriptPath = resolved.path
        return resolvedRecord
    }

    /// The directory cmux must `cd` into to resume or fork this session.
    ///
    /// Many agents store their session under a directory derived from the cwd the session was
    /// *launched* in (Claude `projects/<encode(cwd)>/`, plus the Grok/Pi/Gemini/Cursor/Qoder
    /// cwd-keyed buckets), and `--resume` / `--fork` only locate it from that same directory. The
    /// hook-reported `cwd` drifts when the agent `cd`s elsewhere mid-session (e.g. starting in a
    /// repo root, then moving into a worktree), so trusting it makes resume fail with "No
    /// conversation found". For directory-namespaced kinds, prefer the stable launch cwd (it matches
    /// the namespace and never drifts); for Claude, first verify which candidate actually holds the
    /// transcript. For kinds that key sessions by id and record the cwd inside the session file
    /// (Codex, OpenCode, Amp, …), keep the recorded cwd so the resumed agent reopens where it was.
    private static func restorableWorkingDirectory(
        for record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        registration: CmuxVaultAgentRegistration?,
        claudeTranscriptStore: ClaudeTranscriptStore
    ) -> String? {
        let recordedCwd = normalizedWorkingDirectory(record.cwd)
        let launchCwd = normalizedWorkingDirectory(record.launchCommand?.workingDirectory)

        // Custom Vault agents resume via their own template (which can expand {{cwd}}) and default to
        // a `.preserve` cwd policy, so keep the runtime cwd the agent was working in rather than the
        // launch dir. `.ignore` agents resume from the current directory, so the snapshot must carry
        // no saved cwd at all (downstream restore consumers read `workingDirectory` directly, not just
        // the command builder). The by-directory namespace below is only for built-in agents.
        if let registration {
            return registration.cwd == .ignore ? nil : (recordedCwd ?? launchCwd)
        }

        switch kind.cwdNamespacing {
        case .cwdInFile:
            // Resume is addressed by id and the cwd lives inside the record, so the runtime cwd is
            // fine — keeping it preserves the directory the agent was working in.
            return recordedCwd ?? launchCwd
        case .byDirectory:
            if kind == .claude,
               let verified = claudeTranscriptStore.claudeVerifiedRestorableWorkingDirectory(
                   record: record.claudeTranscriptInput,
                   recordedCwd: recordedCwd,
                   launchCwd: launchCwd
               ) {
                return verified
            }
            // The launch cwd matches the session namespace and never drifts; fall back to the
            // recorded cwd only when no launch cwd was captured.
            return launchCwd ?? recordedCwd
        }
    }

    /// Encodes a cwd into the Claude project directory name.
    ///
    /// Thin forwarder to ``CMUXAgentLaunch/ClaudeTranscriptStore/encodeClaudeProjectDir(_:)``,
    /// kept so the cross-file call sites in `VaultAgentProcessScanner`,
    /// `SessionIndexStore`, `AgentChatTranscriptResolver`, and their tests stay
    /// byte-stable after the resolution cluster moved into `CMUXAgentLaunch`.
    static func encodeClaudeProjectDir(_ path: String) -> String {
        ClaudeTranscriptStore.encodeClaudeProjectDir(path)
    }

    /// Resolves the newest Claude transcript session id for `cwd` (honoring an
    /// optional `CLAUDE_CONFIG_DIR`).
    ///
    /// Thin forwarder to ``CMUXAgentLaunch/ClaudeTranscriptStore/newestClaudeSessionId(forCwd:configDir:homeDirectory:fileManager:)``,
    /// kept so the live-process detection call site in `VaultAgentProcessScanner`
    /// and its tests stay byte-stable after the resolution cluster moved into
    /// `CMUXAgentLaunch`.
    static func newestClaudeSessionId(
        forCwd cwd: String,
        configDir: String?,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        ClaudeTranscriptStore.newestClaudeSessionId(
            forCwd: cwd,
            configDir: configDir,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    private static func liveScopedProcessID(
        for record: RestorableAgentHookSessionRecord,
        kind: RestorableAgentKind,
        workspaceId: UUID,
        panelId: UUID,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?
    ) -> Int? {
        guard let pid = record.pid else {
            return nil
        }
        guard pid > 0,
              let process = processArgumentsProvider(pid),
              process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId) else {
            return nil
        }

        if let liveKind = process.environment["CMUX_AGENT_LAUNCH_KIND"].normalizedProcessValue,
           liveKind.compare(kind.rawValue, options: [.caseInsensitive, .literal]) != .orderedSame {
            return nil
        }

        guard let recordedLaunchCommand = record.launchCommand?.resumeLaunchCommand,
              let recordedExecutable = recordedLaunchCommand.recordedExecutableBasename,
              let liveExecutable = process.arguments.first?.executableBasename else {
            return pid
        }
        guard recordedLaunchCommand.liveProcessExecutableMatchesRecordedAgent(
            isClaude: kind == .claude,
            liveExecutable: liveExecutable,
            recordedExecutable: recordedExecutable,
            arguments: process.arguments
        ) else {
            return nil
        }
        return pid
    }

    /// `value` trimmed of surrounding whitespace and newlines, or `nil` when it
    /// is missing or empty after trimming.
    ///
    /// Shared by the agent session/transcript/working-directory readers in this
    /// type; the process/executable matcher's equivalent is the package-side
    /// `String?.normalizedNonEmptyValue` in `AgentResumeLaunchCommand+ProcessMatch.swift`.
    private static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private init(entriesByPanel: [PanelKey: Entry]) {
        self.entriesByPanel = entriesByPanel
        var entriesByPanelId: [UUID: Entry] = [:]
        for (key, entry) in entriesByPanel {
            let existing = entriesByPanelId[key.panelId]
            if existing == nil || entry.updatedAt >= (existing?.updatedAt ?? 0) {
                entriesByPanelId[key.panelId] = entry
            }
        }
        self.entriesByPanelId = entriesByPanelId
    }
}

nonisolated struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]

    init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]) {
        self.bindingsByPanel = bindingsByPanel
        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        for (key, binding) in bindingsByPanel {
            let existing = bindingsByPanelId[key.panelId]
            if existing == nil || binding.updatedAt >= (existing?.updatedAt ?? 0) {
                bindingsByPanelId[key.panelId] = binding
            }
        }
        self.bindingsByPanelId = bindingsByPanelId
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? bindingsByPanelId[panelId]
    }

    static func loadProcessDetectedBindingsSynchronously(
        fileManager: FileManager = .default
    ) -> SurfaceResumeBindingIndex {
        let detectedBindings = processDetectedTmuxBindings(fileManager: fileManager)
        return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
    }

    static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default
    ) async -> SurfaceResumeBindingIndex {
        await Task.detached(priority: .utility) {
            loadProcessDetectedBindingsSynchronously(fileManager: fileManager)
        }.value
    }
}

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(homeDirectory: homeDirectory, fileManager: fileManager)
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}

private extension CmuxTopProcessArguments {
    func environmentUUID(forKey key: String) -> UUID? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }
}
