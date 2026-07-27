import CmuxFoundation
import Foundation
import CMUXAgentLaunch
import Darwin

/// Coordinates cancellation with `Process.run()`: Foundation raises an
/// Objective-C exception if termination APIs touch a task before launch.
/// Callers own synchronization because the same gate is mutated with adjacent
/// process cancellation state.
struct ProcessTerminationGate: Sendable {
    private var didLaunch = false
    private var didFinish = false
    private var terminationRequested = false

    mutating func requestTermination() -> Bool {
        guard !didFinish else { return false }
        terminationRequested = true
        return didLaunch
    }

    mutating func markLaunched() -> Bool {
        guard !didFinish else { return false }
        didLaunch = true
        return terminationRequested
    }

    mutating func markFinished() {
        didFinish = true
    }
}

enum AgentForkSupport {
    typealias ForkValidationExecutableResolution = (
        status: String,
        lookupPath: String?,
        realPath: String?,
        cachePart: String?,
        watchDirectories: [String]
    )
    typealias ForkProbeExecutableIdentity = (
        lookupPath: String,
        realPath: String,
        cachePart: String,
        watchDirectories: [String]
    )
    enum ForkValidationExecutableResolutionPlan {
        case notRequired
        case skipRemoteLikeContext
        case unresolved
        case run(
            probe: (executable: String, arguments: [String]),
            processEnvironment: [String: String],
            workingDirectory: String?,
            probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool
        )
    }

    static let minimumOpenCodeForkVersion = SemanticVersion(major: 1, minor: 14, patch: 50)
    // Pi v0.60.0 and OMP v13.15.0 are the first releases containing the
    // upstream CLI `--fork <path|id>` implementation.
    static let minimumPiForkVersion = SemanticVersion(major: 0, minor: 60, patch: 0)
    static let minimumOmpForkVersion = SemanticVersion(major: 13, minor: 15, patch: 0)
    private static let piFamilyBareVersionExpression = try! NSRegularExpression(
        pattern: #"^v?\d+\.\d+(?:\.\d+)?$"#
    )
    private static let piFamilyVersionBoundExpressions: [String: NSRegularExpression] = {
        var expressions: [String: NSRegularExpression] = [:]
        for agentID in ["pi", "omp"] {
            let escapedAgentID = NSRegularExpression.escapedPattern(for: agentID)
            let pattern = #"(^|[^a-z0-9])"# + escapedAgentID
                + #"([/\s:_-]+)v?(\d+)\.(\d+)(?:\.(\d+))?($|[\s,;:)\]}])"#
            expressions[agentID] = try! NSRegularExpression(pattern: pattern)
        }
        return expressions
    }()
    static let commandOutputTimeoutNanoseconds: Int64 = 3_000_000_000
    static let commandTerminateTimeoutNanoseconds: Int64 = 500_000_000
    static let executableIdentityResolutionTimeoutNanoseconds: UInt64 = 3_000_000_000
    static let commandOutputMaximumBytes = 64 * 1024

    static func supportsFork(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) async -> Bool {
        let executableIdentityResolver = AgentForkExecutableIdentityResolver()
        let forkCapabilityProbeCache = ForkCapabilityProbeResultCache()
        return await supportsFork(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext,
            executableIdentityResolver: executableIdentityResolver,
            forkCapabilityProbeCache: forkCapabilityProbeCache
        )
    }

    static func supportsFork(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false,
        executableIdentityResolver: AgentForkExecutableIdentityResolver,
        forkCapabilityProbeCache: ForkCapabilityProbeResultCache
    ) async -> Bool {
        guard forkCommandIdentityParts(snapshot: snapshot) != nil else { return false }
        if isRemoteContext,
           snapshot.forkStartupInput(allowLauncherScript: false) == nil {
            return false
        }
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            if isRemoteContext {
                return false
            }
            let fallbackExecutable = snapshot.registration?.defaultExecutable ?? snapshot.kind.rawValue
            let agentID = piFamilyProbeAgentID(snapshot)
            let probe = AgentResumeCommandBuilder.piFamilyVersionProbe(
                launchCommand: snapshot.launchCommand,
                fallbackExecutable: fallbackExecutable
            )
            let acceptsBareVersionOutput = piFamilyProbeExecutableMatchesAgent(
                probe.executable,
                agentID: agentID
            )
            return await supportsLocalForkProbe(
                probe: probe,
                snapshot: snapshot,
                cacheDiscriminator: "pi-family-version:\(agentID)",
                executableIdentityResolver: executableIdentityResolver,
                forkCapabilityProbeCache: forkCapabilityProbeCache,
                probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: true,
                outputSupportsFork: { output in
                    piFamilyVersionSupportsFork(
                        output,
                        agentID: agentID,
                        acceptsBareVersionOutput: acceptsBareVersionOutput
                    )
                }
            )
        }
        guard snapshot.kind == .opencode else { return true }
        if snapshot.launchCommand?.launcher == "omo" {
            return true
        }
        if isRemoteContext {
            return true
        }
        guard let probe = AgentResumeCommandBuilder.openCodeVersionProbe(
            launchCommand: snapshot.launchCommand
        ) else {
            return false
        }
        return await supportsLocalForkProbe(
            probe: probe,
            snapshot: snapshot,
            cacheDiscriminator: "opencode-version",
            executableIdentityResolver: executableIdentityResolver,
            forkCapabilityProbeCache: forkCapabilityProbeCache,
            outputSupportsFork: { output in
                openCodeVersionSupportsFork(output)
            }
        )
    }

    static func forkValidationIdentity(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> String? {
        guard let commandIdentity = forkCommandIdentityParts(snapshot: snapshot) else { return nil }
        var parts = ["command"] + commandIdentity
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            let fallbackExecutable = snapshot.registration?.defaultExecutable ?? snapshot.kind.rawValue
            let agentID = piFamilyProbeAgentID(snapshot)
            let probe = AgentResumeCommandBuilder.piFamilyVersionProbe(
                launchCommand: snapshot.launchCommand,
                fallbackExecutable: fallbackExecutable
            )
            parts.append(
                localForkProbeValidationIdentity(
                    probe: probe,
                    snapshot: snapshot,
                    discriminator: "pi-family-version:\(agentID)",
                    probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: true
                )
            )
        } else if snapshot.kind == .opencode {
            parts.append("opencode")
            parts.append("launcher=\(normalized(snapshot.launchCommand?.launcher) ?? "")")
            if !isRemoteContext,
               let probe = AgentResumeCommandBuilder.openCodeVersionProbe(
                launchCommand: snapshot.launchCommand
               ) {
                parts.append(
                    localForkProbeValidationIdentity(
                        probe: probe,
                        snapshot: snapshot,
                        discriminator: "opencode-version"
                    )
                )
            }
        }
        return parts.joined(separator: "\u{1f}")
    }

    private static func forkCommandIdentityParts(snapshot: SessionRestorableAgentSnapshot) -> [String]? {
        guard snapshot.kind.restoreMode == .resumeSession,
              forkCommandCanRenderWithoutFilesystem(snapshot),
              normalized(snapshot.sessionId) != nil else {
            return nil
        }

        let forkArgv = AgentForkArgv()
        let launchCommand = snapshot.launchCommand
        let launchIdentity = launchCommandIdentityParts(kind: snapshot.kind, launchCommand: launchCommand)
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            guard let argv, !argv.isEmpty else { return nil }
            return ["wrapper"] + argv.map { "argv=\($0)" } + launchIdentity
        case .passthrough:
            break
        }

        if case .custom = snapshot.kind {
            guard let registration = snapshot.registration,
                  let forkCommand = normalized(registration.forkCommand) else {
                return nil
            }
            return [
                "custom",
                "registrationID=\(registration.id)",
                "forkTemplate=\(forkCommand)",
                "defaultExecutable=\(registration.defaultExecutable)",
                "cwdPolicy=\(registration.cwd.rawValue)",
                "sessionDirectory=\(normalized(registration.sessionDirectory) ?? "")",
            ] + launchIdentity
        }

        guard let argv = forkArgv.builtInKind(
            kind: snapshot.kind.rawValue,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? [],
            observedPermissionMode: snapshot.permissionMode
        ), !argv.isEmpty else {
            return nil
        }
        return ["builtIn"] + argv.map { "argv=\($0)" } + launchIdentity
    }

    private static func forkCommandCanRenderWithoutFilesystem(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard snapshot.kind.restoreMode == .resumeSession,
              normalized(snapshot.sessionId) != nil else {
            return false
        }
        let forkArgv = AgentForkArgv()
        let launchCommand = snapshot.launchCommand
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv?.isEmpty == false
        case .passthrough:
            break
        }

        if case .custom = snapshot.kind {
            guard let registration = snapshot.registration,
                  let forkCommand = normalized(registration.forkCommand) else {
                return false
            }
            return customForkTemplateCanRenderWithoutFilesystem(
                forkCommand,
                registration: registration,
                snapshot: snapshot
            )
        }

        return forkArgv.builtInKind(
            kind: snapshot.kind.rawValue,
            sessionId: snapshot.sessionId,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? [],
            observedPermissionMode: snapshot.permissionMode
        )?.isEmpty == false
    }

    private static func customForkTemplateCanRenderWithoutFilesystem(
        _ template: String,
        registration: CmuxVaultAgentRegistration,
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        if template.contains("{{cwd}}"),
           normalized(snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory) == nil {
            return false
        }
        if template.contains("{{sessionDir}}"),
           normalized(registration.sessionDirectory) == nil {
            return false
        }
        if template.contains("{{executable}}") {
            let arguments = snapshot.launchCommand?.arguments ?? []
            let executable = normalized(snapshot.launchCommand?.executablePath)
                ?? arguments.first
                ?? registration.defaultExecutable
            guard normalized(executable) != nil else {
                return false
            }
        }
        return true
    }

    private static func launchCommandIdentityParts(
        kind: RestorableAgentKind,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String] {
        var parts = [
            "launcher=\(normalized(launchCommand?.launcher) ?? "")",
            "executable=\(normalized(launchCommand?.executablePath) ?? "")",
            "cwd=\(normalized(launchCommand?.workingDirectory) ?? "")",
        ]
        parts.append(contentsOf: (launchCommand?.arguments ?? []).map { "launchArg=\($0)" })
        parts.append(contentsOf: launchEnvironmentIdentityParts(kind: kind, environment: launchCommand?.environment))
        return parts
    }

    private static func launchEnvironmentIdentityParts(
        kind: RestorableAgentKind,
        environment: [String: String]?
    ) -> [String] {
        guard let environment, !environment.isEmpty else { return [] }

        var selectedEnvironment: [String: String] = [:]
        let policy = AgentLaunchEnvironmentPolicy()
        for key in environment.keys.sorted() {
            let value: String?
            if key == "CLAUDE_CONFIG_DIR" {
                value = normalized(environment[key])
            } else {
                value = policy.sanitizedValue(key: key, value: environment[key])
            }
            guard let value else { continue }
            selectedEnvironment[key] = value
        }
        let piFamilyUsesCapturedPath = kind == .pi
            || kind.customAgentID == "pi"
            || kind.customAgentID == "omp"
        if piFamilyUsesCapturedPath,
           let path = normalized(environment["PATH"]) {
            selectedEnvironment["PATH"] = path
        }
        return selectedEnvironment.keys.sorted().compactMap { key in
            selectedEnvironment[key].map { value in
                "env:\(key)=\(value)"
            }
        }
    }

    static func requiresLocalPiFamilyCapabilityProbe(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        switch snapshot.kind {
        case .pi:
            guard let registration = snapshot.registration else { return true }
            return registration.forkCommand == CmuxVaultAgentRegistration.builtInPi.forkCommand
        case .custom("pi"):
            return snapshot.registration?.forkCommand == CmuxVaultAgentRegistration.builtInPi.forkCommand
        case .custom("omp"):
            return snapshot.registration?.forkCommand == CmuxVaultAgentRegistration.builtInOmp.forkCommand
        default:
            return false
        }
    }

    private static func piFamilyProbeAgentID(_ snapshot: SessionRestorableAgentSnapshot) -> String {
        if let registrationID = normalizedPiFamilyAgentID(snapshot.registration?.id) {
            return registrationID
        }
        switch snapshot.kind {
        case .pi:
            return "pi"
        case .custom(let agentID):
            if let normalizedAgentID = normalizedPiFamilyAgentID(agentID) {
                return normalizedAgentID
            }
        default:
            break
        }
        let capturedLauncher = snapshot.launchCommand?.launcher?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let capturedExecutable = [
            snapshot.launchCommand?.executablePath,
            snapshot.launchCommand?.arguments.first,
        ]
            .compactMap { value in
                value.map { ($0 as NSString).lastPathComponent.lowercased() }
            }
            .first { $0 == "pi" || $0 == "omp" }
        let capturedLauncherID = capturedLauncher.flatMap {
            ["pi", "omp"].contains($0) ? $0 : nil
        }
        return capturedLauncherID
            ?? capturedExecutable
            ?? snapshot.registration?.id
            ?? snapshot.kind.rawValue
    }

    private static func normalizedPiFamilyAgentID(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == "pi" || normalized == "omp" else { return nil }
        return normalized
    }

    private static func piFamilyProbeExecutableMatchesAgent(_ executable: String, agentID: String) -> Bool {
        let executableName = (executable as NSString).lastPathComponent.lowercased()
        switch agentID {
        case "pi":
            return executableName == "pi" || executableName == "pi-coding-agent"
        case "omp":
            return executableName == "omp"
        default:
            return false
        }
    }

    static func piFamilyVersionSupportsFork(
        _ output: String,
        agentID: String,
        acceptsBareVersionOutput: Bool = false
    ) -> Bool {
        guard let version = piFamilyProbeVersion(
            in: output,
            agentID: agentID,
            acceptsBareVersionOutput: acceptsBareVersionOutput
        ) else { return false }
        switch agentID {
        case "pi":
            return version >= minimumPiForkVersion
        case "omp":
            return version >= minimumOmpForkVersion
        default:
            return false
        }
    }

    private static func piFamilyProbeVersion(
        in output: String,
        agentID: String,
        acceptsBareVersionOutput: Bool
    ) -> SemanticVersion? {
        let normalizedAgentID = agentID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedAgentID == "pi" || normalizedAgentID == "omp" else { return nil }
        guard let boundExpression = piFamilyVersionBoundExpressions[normalizedAgentID] else { return nil }

        var candidates: [SemanticVersion] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = line.lowercased()
            let lineRange = NSRange(lowercasedLine.startIndex..<lowercasedLine.endIndex, in: lowercasedLine)
            let isBareVersionLine = piFamilyBareVersionExpression.firstMatch(
                in: lowercasedLine,
                range: lineRange
            ) != nil
            if acceptsBareVersionOutput && isBareVersionLine,
               let version = SemanticVersion.first(in: lowercasedLine) {
                candidates.append(version)
                continue
            }
            if let version = piFamilyVersionBoundToAgent(
                lowercasedLine,
                expression: boundExpression,
                range: lineRange
            ) {
                candidates.append(version)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func piFamilyVersionBoundToAgent(
        _ line: String,
        expression: NSRegularExpression,
        range: NSRange
    ) -> SemanticVersion? {
        guard let match = expression.firstMatch(in: line, range: range) else { return nil }

        func integer(at captureIndex: Int, fallback defaultValue: Int? = nil) -> Int? {
            let captureRange = match.range(at: captureIndex)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: line) else {
                return defaultValue
            }
            return Int(line[range])
        }

        guard let major = integer(at: 3),
              let minor = integer(at: 4) else {
            return nil
        }
        return SemanticVersion(major: major, minor: minor, patch: integer(at: 5, fallback: 0) ?? 0)
    }

    static func openCodeVersionSupportsFork(_ output: String) -> Bool {
        guard let version = SemanticVersion.first(in: output) else {
            return false
        }
        return version >= minimumOpenCodeForkVersion
    }

    private static func supportsLocalForkProbe(
        probe: (executable: String, arguments: [String]),
        snapshot: SessionRestorableAgentSnapshot,
        cacheDiscriminator: String,
        executableIdentityResolver: AgentForkExecutableIdentityResolver,
        forkCapabilityProbeCache: ForkCapabilityProbeResultCache,
        probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool = false,
        outputSupportsFork: @Sendable (String) -> Bool
    ) async -> Bool {
        let requestedWorkingDirectory = probeWorkingDirectory(snapshot: snapshot)
        let processEnvironment = processEnvironmentForOpenCodeProbe(environment: snapshot.launchCommand?.environment)
        let workingDirectory = requestedWorkingDirectory
        guard let executableIdentity = await executableIdentityResolver.identityIfRunnable(
            probe: probe,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory,
            probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
        ) else {
            return false
        }
        let cacheKey = forkProbeCacheKey(
            probe: probe,
            processEnvironment: processEnvironment,
            executableIdentity: executableIdentity.cachePart,
            workingDirectory: workingDirectory,
            discriminator: cacheDiscriminator
        )
        let probeStartedAt = Date().timeIntervalSinceReferenceDate
        if let cached = await forkCapabilityProbeCache.value(for: cacheKey, now: probeStartedAt) {
            return cached
        }
        guard let output = await commandOutput(
            executable: probe.executable,
            arguments: probe.arguments,
            environment: snapshot.launchCommand?.environment,
            workingDirectory: workingDirectory
        ) else {
            return false
        }
        let supportsFork = outputSupportsFork(output)
        let executableIdentityAfterProbe = await executableIdentityResolver.identityIfRunnable(
            probe: probe,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory,
            probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
        )
        guard executableIdentityAfterProbe?.cachePart == executableIdentity.cachePart else {
            return supportsFork
        }
        await forkCapabilityProbeCache.store(supportsFork, for: cacheKey, now: probeStartedAt)
        return supportsFork
    }

    private static func localForkProbeValidationIdentity(
        probe: (executable: String, arguments: [String]),
        snapshot: SessionRestorableAgentSnapshot,
        discriminator: String,
        probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool = false
    ) -> String {
        let requestedWorkingDirectory = probeWorkingDirectory(snapshot: snapshot)
        let workingDirectory = requestedWorkingDirectory
        let directoryPolicy = probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
            ? "default-directory-when-missing"
            : "requested-directory"
        return [
            directoryPolicy,
            forkProbeCacheKey(
                probe: probe,
                processEnvironment: processEnvironmentForOpenCodeProbeValidationIdentity(
                    environment: snapshot.launchCommand?.environment
                ),
                executableIdentity: nil,
                workingDirectory: workingDirectory,
                discriminator: discriminator
            ),
        ].joined(separator: "\u{1f}")
    }

    private static func forkProbeCacheKey(
        probe: (executable: String, arguments: [String]),
        processEnvironment: [String: String],
        executableIdentity: String?,
        workingDirectory: String?,
        discriminator: String
    ) -> String {
        let environmentParts = processEnvironment.keys.sorted().compactMap { key in
            processEnvironment[key].map { value in
                "\(key)=\(value)"
            }
        }
        return ([discriminator, probe.executable, "exec=\(executableIdentity ?? "unresolved")"] + probe.arguments + environmentParts + ["cwd=\(workingDirectory ?? "")"])
            .joined(separator: "\u{1f}")
    }

    static func forkProbeExecutableIdentityIfRunnable(
        probe: (executable: String, arguments: [String]),
        processEnvironment: [String: String],
        workingDirectory: String?,
        probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool
    ) -> ForkProbeExecutableIdentity? {
        let usesDefaultDirectoryForMissingWorkingDirectory = probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
            && workingDirectory.flatMap({ localDirectoryURL(path: $0) }) == nil
        if usesDefaultDirectoryForMissingWorkingDirectory {
            return nil
        }
        switch localForkProbeDecision(probe: probe, workingDirectory: workingDirectory) {
        case .run:
            break
        case .skipRemoteLikeContext:
            return nil
        case .rejectMissingWorkingDirectory:
            return nil
        case .rejectMissingExecutable:
            return nil
        }
        return forkProbeExecutableIdentity(
            executable: probe.executable,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory
        )
    }

    static func forkProbeExecutableIdentity(
        executable: String,
        processEnvironment: [String: String],
        workingDirectory: String?
    ) -> ForkProbeExecutableIdentity? {
        guard let executableResolution = resolvedProbeExecutable(
            executable: executable,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory
        ) else {
            return nil
        }
        let executablePath = executableResolution.path
        var status = stat()
        guard stat(executablePath, &status) == 0 else {
            return nil
        }
        let realPath = realpath(executablePath, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? executablePath
        let cachePart = [
            realPath,
            "dev=\(status.st_dev)",
            "ino=\(status.st_ino)",
            "mode=\(status.st_mode)",
            "size=\(status.st_size)",
            "mtime=\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)",
            "ctime=\(status.st_ctimespec.tv_sec).\(status.st_ctimespec.tv_nsec)",
        ].joined(separator: ":")
        return (
            lookupPath: executablePath,
            realPath: realPath,
            cachePart: cachePart,
            watchDirectories: executableResolution.watchDirectories
        )
    }

    static func requiresForkValidationExecutableIdentity(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> Bool {
        guard !isRemoteContext else { return false }
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            return true
        }
        return snapshot.kind == .opencode
            && snapshot.launchCommand?.launcher != "omo"
            && AgentResumeCommandBuilder.openCodeVersionProbe(launchCommand: snapshot.launchCommand) != nil
    }

    static func forkValidationExecutableResolution(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> ForkValidationExecutableResolution {
        switch forkValidationExecutableResolutionPlan(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        ) {
        case .notRequired:
            return ("notRequired", nil, nil, nil, [])
        case .skipRemoteLikeContext:
            return ("skipRemoteLikeContext", nil, nil, nil, [])
        case .unresolved:
            return ("unresolved", nil, nil, nil, [])
        case .run(let probe, let processEnvironment, let workingDirectory, _):
            guard let identity = forkProbeExecutableIdentity(
                executable: probe.executable,
                processEnvironment: processEnvironment,
                workingDirectory: workingDirectory
            ) else {
                return ("unresolved", nil, nil, nil, [])
            }
            return ("resolved", identity.lookupPath, identity.realPath, identity.cachePart, identity.watchDirectories)
        }
    }

    static func forkValidationExecutableResolutionWorkIdentity(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> String? {
        switch forkValidationExecutableResolutionPlan(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        ) {
        case .run(let probe, let processEnvironment, let workingDirectory, let probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing):
            return ([
                "remote=\(isRemoteContext)",
                "defaultOnMissingCwd=\(probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing)",
                probe.executable,
                "cwd=\(workingDirectory ?? "")",
            ] + probe.arguments + processEnvironment.keys.sorted().compactMap { key in
                processEnvironment[key].map { "\(key)=\($0)" }
            }).joined(separator: "\u{1f}")
        case .notRequired, .skipRemoteLikeContext, .unresolved:
            return nil
        }
    }

    static func forkValidationExecutableResolutionPlan(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> ForkValidationExecutableResolutionPlan {
        guard requiresForkValidationExecutableIdentity(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        ) else { return .notRequired }
        let fallbackExecutable: String
        let probe: (executable: String, arguments: [String])
        let useDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool
        if requiresLocalPiFamilyCapabilityProbe(snapshot) {
            fallbackExecutable = snapshot.registration?.defaultExecutable ?? snapshot.kind.rawValue
            probe = AgentResumeCommandBuilder.piFamilyVersionProbe(
                launchCommand: snapshot.launchCommand,
                fallbackExecutable: fallbackExecutable
            )
            useDefaultDirectoryWhenWorkingDirectoryIsMissing = true
        } else if snapshot.kind == .opencode,
                  snapshot.launchCommand?.launcher != "omo",
                  let openCodeProbe = AgentResumeCommandBuilder.openCodeVersionProbe(
                    launchCommand: snapshot.launchCommand
                  ) {
            probe = openCodeProbe
            useDefaultDirectoryWhenWorkingDirectoryIsMissing = false
        } else {
            return .notRequired
        }

        let requestedWorkingDirectory = probeWorkingDirectory(snapshot: snapshot)
        let processEnvironment = processEnvironmentForOpenCodeProbe(environment: snapshot.launchCommand?.environment)
        let usesDefaultDirectoryForMissingWorkingDirectory = useDefaultDirectoryWhenWorkingDirectoryIsMissing
            && requestedWorkingDirectory.flatMap({ localDirectoryURL(path: $0) }) == nil
        if usesDefaultDirectoryForMissingWorkingDirectory {
            return .unresolved
        }
        let workingDirectory = requestedWorkingDirectory
        switch localForkProbeDecision(probe: probe, workingDirectory: workingDirectory) {
        case .run:
            break
        case .skipRemoteLikeContext:
            return .skipRemoteLikeContext
        case .rejectMissingWorkingDirectory:
            return .unresolved
        case .rejectMissingExecutable:
            return .unresolved
        }
        return .run(
            probe: probe,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory,
            probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: useDefaultDirectoryWhenWorkingDirectoryIsMissing
        )
    }

    static func forkValidationExecutableFingerprint(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> String {
        forkValidationExecutableFingerprint(
            forkValidationExecutableResolution(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            )
        )
    }

    static func forkValidationExecutableFingerprint(
        _ executableResolution: ForkValidationExecutableResolution
    ) -> String {
        let parts: [String] = [
            executableResolution.status,
            executableResolution.lookupPath ?? "",
            executableResolution.realPath ?? "",
            executableResolution.cachePart ?? "",
            executableResolution.watchDirectories.joined(separator: "\u{1f}")
        ]
        return parts.joined(separator: "\u{1e}")
    }

    static func forkValidationExecutableIdentity(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool = false
    ) -> (lookupPath: String, realPath: String, cachePart: String)? {
        let resolution = forkValidationExecutableResolution(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        )
        guard resolution.status == "resolved",
              let lookupPath = resolution.lookupPath,
              let realPath = resolution.realPath,
              let cachePart = resolution.cachePart else {
            return nil
        }
        return (lookupPath, realPath, cachePart)
    }

    private static func resolvedProbeExecutable(
        executable: String,
        processEnvironment: [String: String],
        workingDirectory: String?
    ) -> (path: String, watchDirectories: [String])? {
        let baseDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
        func absolutePath(_ path: String) -> String {
            if path.hasPrefix("/") {
                return path
            }
            return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: baseDirectory, isDirectory: true))
                .standardizedFileURL
                .path
        }

        if executable.contains("/") {
            let path = absolutePath(executable)
            guard isRegularExecutableFile(atPath: path) else { return nil }
            return (path, [URL(fileURLWithPath: path).deletingLastPathComponent().path])
        }

        let pathDirectories = (processEnvironment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        var watchDirectories: [String] = []
        for directory in pathDirectories {
            let candidate = absolutePath((directory.isEmpty ? "." : directory) + "/" + executable)
            watchDirectories.append(URL(fileURLWithPath: candidate).deletingLastPathComponent().path)
            if isRegularExecutableFile(atPath: candidate) {
                return (candidate, watchDirectories)
            }
        }
        return nil
    }

    private static func isRegularExecutableFile(atPath path: String) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        guard (status.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    static func probeOutputPipeHandles(
        readFileDescriptor: Int32,
        writeFileDescriptor: Int32
    ) -> Set<UInt64> {
        var handles = Set<UInt64>()
        handles.formUnion(probeOutputPipeHandles(fileDescriptor: readFileDescriptor))
        handles.formUnion(probeOutputPipeHandles(fileDescriptor: writeFileDescriptor))
        return handles
    }

    static func probeOutputPipeHandles(
        fileDescriptor: Int32,
        processIdentifier: pid_t = Darwin.getpid()
    ) -> Set<UInt64> {
        var pipeInfo = pipe_fdinfo()
        let byteCount = proc_pidfdinfo(
            Int32(processIdentifier),
            fileDescriptor,
            PROC_PIDFDPIPEINFO,
            &pipeInfo,
            Int32(MemoryLayout<pipe_fdinfo>.size)
        )
        guard byteCount == MemoryLayout<pipe_fdinfo>.size else {
            return []
        }
        return Set([
            pipeInfo.pipeinfo.pipe_handle,
            pipeInfo.pipeinfo.pipe_peerhandle,
        ].filter { $0 != 0 })
    }

    static func processIdentifiersHoldingProbeOutputPipe(
        _ outputPipeHandles: Set<UInt64>,
        excluding excludedProcessIdentifiers: Set<pid_t>
    ) -> [pid_t] {
        guard !outputPipeHandles.isEmpty else { return [] }
        var processIdentifiers = [pid_t](repeating: 0, count: 8192)
        let returnedProcessIdentifierCount = processIdentifiers.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard returnedProcessIdentifierCount > 0 else { return [] }
        let processIdentifierCount = min(
            processIdentifiers.count,
            Int(returnedProcessIdentifierCount)
        )
        var matches: [pid_t] = []
        for processIdentifier in processIdentifiers.prefix(processIdentifierCount) where processIdentifier > 0 {
            guard !excludedProcessIdentifiers.contains(processIdentifier),
                  processHoldsProbeOutputPipe(processIdentifier, outputPipeHandles: outputPipeHandles) else {
                continue
            }
            matches.append(processIdentifier)
        }
        return matches
    }

    private typealias ProbeProcessTreeEntry = (
        parentProcessIdentifier: pid_t,
        startMicroseconds: Int64
    )

    static func probeRelatedPipeHolderProcessIdentifiers(
        _ holdingProcessIdentifiers: [pid_t],
        probeRootProcessIdentifier: pid_t,
        probeRootStartMicroseconds: Int64,
        verifiedStartMicrosecondsByProcessIdentifier: [pid_t: Int64]
    ) -> (
        processIdentifiers: [pid_t],
        verifiedStartMicrosecondsByProcessIdentifier: [pid_t: Int64]
    ) {
        guard !holdingProcessIdentifiers.isEmpty else {
            return ([], verifiedStartMicrosecondsByProcessIdentifier)
        }
        let processTree = probeProcessTreeEntriesByProcessIdentifier()
        var verified = verifiedStartMicrosecondsByProcessIdentifier
        var related: [pid_t] = []
        for processIdentifier in holdingProcessIdentifiers {
            guard let entry = processTree[processIdentifier] else { continue }
            if let verifiedStartMicroseconds = verified[processIdentifier],
               verifiedStartMicroseconds != entry.startMicroseconds {
                continue
            }
            if processIdentifier == probeRootProcessIdentifier {
                guard entry.startMicroseconds == probeRootStartMicroseconds else { continue }
            }
            verified[processIdentifier] = entry.startMicroseconds
            related.append(processIdentifier)
        }
        return (related, verified)
    }

    private static func probeProcessTreeEntriesByProcessIdentifier() -> [pid_t: ProbeProcessTreeEntry] {
        let pidStride = MemoryLayout<pid_t>.stride
        let initialProcessIdentifierCount = Int(proc_listallpids(nil, 0))
        guard initialProcessIdentifierCount > 0 else { return [:] }
        var capacity = max(1, initialProcessIdentifierCount + 32)
        var lastProcessIdentifiers: [pid_t] = []
        var lastProcessIdentifierCount = 0
        for _ in 0..<3 {
            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            let returnedProcessIdentifierCount = processIdentifiers.withUnsafeMutableBufferPointer { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count * pidStride))
            }
            guard returnedProcessIdentifierCount >= 0 else {
                break
            }
            let count = min(processIdentifiers.count, Int(returnedProcessIdentifierCount))
            if count > 0 {
                lastProcessIdentifiers = processIdentifiers
                lastProcessIdentifierCount = count
            }
            if returnedProcessIdentifierCount < processIdentifiers.count {
                break
            }
            capacity = max(processIdentifiers.count * 2, Int(returnedProcessIdentifierCount) + 32)
        }
        guard lastProcessIdentifierCount > 0 else { return [:] }

        var processTree: [pid_t: ProbeProcessTreeEntry] = [:]
        for processIdentifier in lastProcessIdentifiers.prefix(lastProcessIdentifierCount)
        where processIdentifier > 0 {
            guard let bsdInfo = processBSDInfo(processIdentifier: processIdentifier) else {
                continue
            }
            processTree[processIdentifier] = (
                parentProcessIdentifier: pid_t(bsdInfo.pbi_ppid),
                startMicroseconds: Int64(bsdInfo.pbi_start_tvsec) * 1_000_000
                    + Int64(bsdInfo.pbi_start_tvusec)
            )
        }
        return processTree
    }

    private static func processBSDInfo(processIdentifier: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return info
    }

    static func processStartMicroseconds(processIdentifier: pid_t) -> Int64? {
        guard let bsdInfo = processBSDInfo(processIdentifier: processIdentifier) else {
            return nil
        }
        return Int64(bsdInfo.pbi_start_tvsec) * 1_000_000
            + Int64(bsdInfo.pbi_start_tvusec)
    }

    static func processStillHoldsProbeOutputPipe(
        _ processIdentifier: pid_t,
        outputPipeHandles: Set<UInt64>,
        expectedStartMicroseconds: Int64
    ) -> Bool {
        guard processStartMicroseconds(processIdentifier: processIdentifier) == expectedStartMicroseconds else {
            return false
        }
        return processHoldsProbeOutputPipe(
            processIdentifier,
            outputPipeHandles: outputPipeHandles
        )
    }

    private static func processHoldsProbeOutputPipe(
        _ processIdentifier: pid_t,
        outputPipeHandles: Set<UInt64>
    ) -> Bool {
        var fileDescriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let fileDescriptorBytes = fileDescriptors.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(
                Int32(processIdentifier),
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<proc_fdinfo>.size)
            )
        }
        guard fileDescriptorBytes > 0 else { return false }
        let fileDescriptorCount = min(
            fileDescriptors.count,
            Int(fileDescriptorBytes) / MemoryLayout<proc_fdinfo>.size
        )
        for fileDescriptorInfo in fileDescriptors.prefix(fileDescriptorCount)
        where fileDescriptorInfo.proc_fdtype == PROX_FDTYPE_PIPE {
            let handles = probeOutputPipeHandles(
                fileDescriptor: fileDescriptorInfo.proc_fd,
                processIdentifier: processIdentifier
            )
            if !handles.isDisjoint(with: outputPipeHandles) {
                return true
            }
        }
        return false
    }

    private static func commandOutput(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?
    ) async -> String? {
        let runner = AgentForkCommandOutputRunner(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        return await withTaskCancellationHandler {
            await runner.start()
        } onCancel: {
            runner.cancel()
        }
    }

    static func processEnvironmentForOpenCodeProbe(
        environment: [String: String]?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var processEnvironment = sanitizedBaseEnvironmentForOpenCodeProbe(baseEnvironment)
        if let environment {
            let selectedEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: environment)
            for (key, value) in selectedEnvironment {
                processEnvironment[key] = value
            }
        }
        if let path = environment?["PATH"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processEnvironment["PATH"] = path
        } else if processEnvironment["PATH"] == nil {
            processEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return processEnvironment
    }

    private static func processEnvironmentForOpenCodeProbeValidationIdentity(
        environment: [String: String]?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var processEnvironment = sanitizedBaseEnvironmentForOpenCodeProbeValidationIdentity(baseEnvironment)
        if let environment {
            mergeSelectedEnvironmentForOpenCodeProbeValidationIdentity(environment, into: &processEnvironment)
        }
        if let path = environment?["PATH"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processEnvironment["PATH"] = path
        } else if processEnvironment["PATH"] == nil {
            processEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return processEnvironment
    }

    private static func sanitizedBaseEnvironmentForOpenCodeProbe(_ environment: [String: String]) -> [String: String] {
        let safeBaseKeys = [
            "HOME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "PATH",
            "TMPDIR",
            "USER"
        ]
        var processEnvironment: [String: String] = [:]
        for key in safeBaseKeys {
            guard let value = environment[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            processEnvironment[key] = value
        }
        let selectedEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: environment)
        for (key, value) in selectedEnvironment {
            processEnvironment[key] = value
        }
        return processEnvironment
    }

    private static func sanitizedBaseEnvironmentForOpenCodeProbeValidationIdentity(
        _ environment: [String: String]
    ) -> [String: String] {
        let safeBaseKeys = [
            "HOME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "PATH",
            "TMPDIR",
            "USER"
        ]
        var processEnvironment: [String: String] = [:]
        for key in safeBaseKeys {
            guard let value = environment[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            processEnvironment[key] = value
        }
        mergeSelectedEnvironmentForOpenCodeProbeValidationIdentity(environment, into: &processEnvironment)
        return processEnvironment
    }

    private static func mergeSelectedEnvironmentForOpenCodeProbeValidationIdentity(
        _ environment: [String: String],
        into processEnvironment: inout [String: String]
    ) {
        let policy = AgentLaunchEnvironmentPolicy()
        for key in environment.keys.sorted() {
            let value: String?
            if key == "CLAUDE_CONFIG_DIR" {
                value = normalized(environment[key])
            } else {
                value = policy.sanitizedValue(key: key, value: environment[key])
            }
            guard let value else { continue }
            processEnvironment[key] = value
        }
    }

    private static func probeWorkingDirectory(snapshot: SessionRestorableAgentSnapshot) -> String? {
        normalized(snapshot.workingDirectory) ?? normalized(snapshot.launchCommand?.workingDirectory)
    }

    private enum LocalForkProbeDecision {
        case run
        case skipRemoteLikeContext
        case rejectMissingWorkingDirectory
        case rejectMissingExecutable
    }

    private static func localForkProbeDecision(
        probe: (executable: String, arguments: [String]),
        workingDirectory: String?
    ) -> LocalForkProbeDecision {
        if let workingDirectory, localDirectoryURL(path: workingDirectory) == nil {
            return .rejectMissingWorkingDirectory
        }
        if probe.executable.hasPrefix("/") {
            return isRegularExecutableFile(atPath: probe.executable)
                ? .run
                : .rejectMissingExecutable
        }
        return .run
    }

    static func localDirectoryURL(path: String?) -> URL? {
        guard let path = normalized(path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

actor ForkCapabilityProbeResultCache {
    private let cache: AgentForkCapabilityProbeCache
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 30, maxEntries: Int = 128) {
        self.cache = AgentForkCapabilityProbeCache(maxEntries: maxEntries)
        self.ttl = ttl
    }

    func value(for key: String, now: TimeInterval) async -> Bool? {
        await cache.value(for: key, now: now)
    }

    func store(_ value: Bool, for key: String, now: TimeInterval) async {
        await cache.store(value, for: key, now: now, expiresAt: now + ttl)
    }
}
