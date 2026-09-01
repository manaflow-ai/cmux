import CmuxFoundation
import CmuxSentryReporting
import CmuxSettings
import Darwin
import Foundation

#if canImport(Sentry)
// Sentry Cocoa 9.3.0 is pinned in Package.resolved. This SPI stores the
// envelope durably without blocking short-lived CLI commands; verify it before
// any Sentry SDK upgrade.
@_spi(Private) import Sentry
#endif

enum CLISocketEnvironment {
    static func socketPath(in environment: [String: String]) throws -> String? {
        let socketPath = normalized(environment["CMUX_SOCKET_PATH"])
        let legacySocketPath = normalized(environment["CMUX_SOCKET"])
        if let socketPath, let legacySocketPath, socketPath != legacySocketPath {
            throw CLIError(message: String(
                localized: "cli.socket.error.conflictingEnvironment",
                defaultValue: "Refusing to choose socket: CMUX_SOCKET_PATH and CMUX_SOCKET differ. Use CMUX_SOCKET_PATH or unset CMUX_SOCKET."
            ))
        }
        return socketPath ?? legacySocketPath
    }

    static func socketPathForTelemetry(in environment: [String: String]) -> String? {
        normalized(environment["CMUX_SOCKET_PATH"]) ?? normalized(environment["CMUX_SOCKET"])
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class CLISocketSentryTelemetry {
    private struct PendingBreadcrumb {
        let message: String
        let data: [String: Any]
    }

    private typealias CLIErrorMetadata = (
        code: String?,
        socketPathMissing: Bool,
        legacyMessage: String?,
        isStructuredProtocolResponse: Bool
    )

    private typealias ErrorClassification = (
        errorDescription: String,
        metadata: CLIErrorMetadata,
        isExpected: Bool
    )

    private let command: String
    private let subcommand: String
    private let socketPath: String
    private let envSocketPath: String?
    private let processEnv: [String: String]
    private let workspaceId: String?
    private let surfaceId: String?
    private let disabledByEnv: Bool
    private let noiseFilter: SentryNoiseFilter
    private let sentryPolicy: CLISocketSentryPolicy
    private let buildIdentityPolicy: SentryBuildIdentityPolicy
    private var pendingBreadcrumbs: [PendingBreadcrumb] = []

#if canImport(Sentry)
    private static let startupLock = NSLock()
    private static var started = false
    private static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
#endif

    private static func currentSentryReleaseName() -> String? {
        guard let bundleIdentifier = currentSentryBundleIdentifier(),
              let version = currentBundleVersionValue(forKey: "CFBundleShortVersionString"),
              let build = currentBundleVersionValue(forKey: "CFBundleVersion")
        else {
            return nil
        }
        return "\(bundleIdentifier)@\(version)+\(build)"
    }

    private static func currentSentryBundleIdentifier(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let bundleIdentifier = environment["CMUX_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = currentSentryBundle()?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    private static func currentBundleVersionValue(forKey key: String) -> String? {
        guard let value = currentSentryBundle()?.infoDictionary?[key] as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private static func currentSentryBundle() -> Bundle? {
        if Bundle.main.bundleIdentifier?.isEmpty == false {
            return Bundle.main
        }

        if let bundle = CLIExecutableLocator.enclosingAppBundle() {
            return bundle
        }

        return Bundle.main
    }

    init(command: String, commandArgs: [String], socketPath: String, processEnv: [String: String]) {
        self.command = command.lowercased()
        self.subcommand = commandArgs.first?.lowercased() ?? "help"
        self.socketPath = socketPath
        self.envSocketPath = CLISocketEnvironment.socketPathForTelemetry(in: processEnv)
        self.processEnv = processEnv
        self.workspaceId = processEnv["CMUX_WORKSPACE_ID"]
        self.surfaceId = processEnv["CMUX_SURFACE_ID"]
        self.disabledByEnv =
            processEnv["CMUX_CLI_SENTRY_DISABLED"] == "1" ||
            processEnv["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] == "1"
        self.noiseFilter = SentryNoiseFilter()
        self.sentryPolicy = CLISocketSentryPolicy(environment: processEnv)
        // The cmux repo is public; rebranded forks have shipped with this
        // CLI's hardcoded DSN intact. Only a build that identifies as cmux
        // may report to it (Sentry issue CMUXTERM-MACOS-1RZF).
        self.buildIdentityPolicy = SentryBuildIdentityPolicy(
            bundleIdentifier: Self.currentSentryBundleIdentifier(environment: processEnv),
            trustedBaseBundleIdentifier: SocketPathMarkerFiles.stableBundleIdentifier
        )
    }

    func breadcrumb(_ message: String, data: [String: Any] = [:]) {
        guard shouldEmit else { return }
#if canImport(Sentry)
        pendingBreadcrumbs.append(PendingBreadcrumb(message: message, data: data))
#endif
    }

    /// Captures an actionable CLI failure while preserving the original error
    /// for classification when the emitted Sentry error is deliberately
    /// privacy-reduced (for example, agent-hook summaries).
    func captureError(
        stage: String,
        error: Error,
        data: [String: Any] = [:],
        classificationError: Error? = nil
    ) {
        guard shouldEmit,
              let classification = classify(
            stage: stage,
            error: error,
            data: data,
            classificationError: classificationError
        ) else {
            return
        }
        let errorDescription = classification.errorDescription
        let cliErrorMetadata = classification.metadata
        guard !classification.isExpected else { return }
        let fingerprintKind = Self.fingerprintKind(
            for: classificationError ?? error,
            message: errorDescription,
            structuredCode: cliErrorMetadata.code
        )
        if let fingerprintKind,
           CLISentryErrorFingerprint.throttledKinds.contains(fingerprintKind),
           !claimThrottledCaptureSlot(stage: stage, kind: fingerprintKind) {
            return
        }
#if DEBUG
        recordCaptureProbe(stage: stage, error: error)
#endif
#if canImport(Sentry)
        Self.ensureStarted()
        var context = baseContext()
        context["stage"] = stage
        context["error"] = errorDescription
        if let code = cliErrorMetadata.code {
            context["cli_error_code"] = code
        }
        if cliErrorMetadata.isStructuredProtocolResponse {
            context["cli_error_protocol_response"] = true
        }
        if cliErrorMetadata.socketPathMissing {
            context["socket_path_missing"] = true
        }
        for (key, value) in socketDiagnostics() {
            context[key] = value
        }
        for (key, value) in data {
            context[key] = value
        }
        let subcommand = self.subcommand
        let command = self.command
        let event = Self.makeErrorEvent(
            error: error,
            context: context,
            command: command,
            subcommand: subcommand,
            fingerprint: ["cmux-cli", stage, fingerprintKind ?? "{{ default }}"],
            breadcrumbs: pendingBreadcrumbs.map { pending in
                makeBreadcrumb(message: pending.message, data: pending.data)
            }
        )
        pendingBreadcrumbs.removeAll()
        let scrubber = SentryEventScrubber()
        let scrubbedEvent = scrubber.scrub(event)
        guard !Self.isExpectedCLISocketTransportEvent(
            scrubbedEvent,
            classificationMessage: cliErrorMetadata.legacyMessage
        ) else {
            return
        }
        let envelopeItem = SentryEnvelopeItem(event: scrubbedEvent)
        let envelope = SentryEnvelope(id: scrubbedEvent.eventId, singleItem: envelopeItem)
        PrivateSentrySDKOnly.store(envelope)
        // `store` is the durable handoff. Calling SentrySDK.flush here—even
        // with a zero timeout—still enters SentryHttpTransport's synchronous
        // coordination path. The app's Sentry client will pick up the cached
        // envelope on its next transport pass.
#if DEBUG
        recordStoreProbe(
            eventId: scrubbedEvent.eventId.sentryIdString,
            fingerprint: scrubbedEvent.fingerprint ?? []
        )
#endif
#endif
    }

    private var shouldEmit: Bool {
        !disabledByEnv && buildIdentityPolicy.allowsTelemetry
    }

    /// Returns whether a failure is expected and should skip telemetry work.
    /// This read-only preflight lets agent-hook throttles classify before they
    /// reserve a durable report slot.
    func isExpectedFailure(
        stage: String,
        error: Error,
        data: [String: Any] = [:],
        classificationError: Error? = nil
    ) -> Bool {
        guard shouldEmit,
              let classification = classify(
            stage: stage,
            error: error,
            data: data,
            classificationError: classificationError
        ) else {
            return false
        }
        return classification.isExpected
    }

    private func classify(
        stage: String,
        error: Error,
        data: [String: Any],
        classificationError: Error?
    ) -> ErrorClassification? {
        guard shouldEmit else { return nil }
        let errorDescription = String(describing: error)
        let classificationCandidate = classificationError ?? error
        let cliErrorMetadata = metadata(for: classificationCandidate)
        let classificationMessage = cliErrorMetadata.legacyMessage
            ?? String(describing: classificationCandidate)
        let dataKeys = Set(data.keys)
        let isAgentHookStage = stage.hasPrefix("agent-hook-")
        let hasStructuredCLIErrorCode = cliErrorMetadata.code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let isExpectedAgentHookCLIError =
            isAgentHookStage &&
            (noiseFilter.isExpectedCLIAppLifecycleError(
                code: cliErrorMetadata.code,
                message: classificationMessage
            ) ||
                cliErrorMetadata.socketPathMissing)
        let isExpectedLegacyCLIError: Bool
        if !hasStructuredCLIErrorCode {
            isExpectedLegacyCLIError =
                noiseFilter.isExpectedCLISocketTransportFailure(
                    stage: stage,
                    message: classificationMessage,
                    dataKeys: dataKeys,
                    allowSandboxPolicyDenial: sentryPolicy.allowsSandboxPolicyDenial
                ) ||
                (isAgentHookStage &&
                    noiseFilter.isExpectedLegacyCLIAppLifecycleMessage(classificationMessage))
        } else {
            isExpectedLegacyCLIError = false
        }
        let isExpectedTransportFailure = noiseFilter.isExpectedCLISocketTransportFailure(
            stage: stage,
            message: errorDescription,
            dataKeys: dataKeys,
            allowSandboxPolicyDenial: sentryPolicy.allowsSandboxPolicyDenial,
            cliErrorCode: cliErrorMetadata.code,
            socketPathMissing: cliErrorMetadata.socketPathMissing
        )
        let isExpectedProtocolOutcome =
            cliErrorMetadata.isStructuredProtocolResponse &&
            noiseFilter.isExpectedCLIProtocolOutcomeCode(cliErrorMetadata.code)
        return (
            errorDescription: errorDescription,
            metadata: cliErrorMetadata,
            isExpected: isExpectedAgentHookCLIError ||
                isExpectedLegacyCLIError ||
                isExpectedTransportFailure ||
                isExpectedProtocolOutcome
        )
    }

    /// Chooses the stable fingerprint kind for a CLI failure: the structured
    /// v2 protocol error code when the app replied with one, else the known
    /// transport failure class of the rendered message, else `nil` so the
    /// event keeps Sentry's default grouping within its stage.
    private static func fingerprintKind(
        for error: Error,
        message: String,
        structuredCode: String? = nil
    ) -> String? {
        if let v2Code = (structuredCode ?? (error as? CLIError)?.v2Code)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !v2Code.isEmpty {
            return "v2-\(v2Code)"
        }
        return CLISentryErrorFingerprint().kind(forMessage: message)
    }

    /// One durable capture per (stage, kind) per throttle interval for
    /// expected-but-reportable volume states like command timeouts, which
    /// otherwise fire once per agent hook invocation while the app is wedged.
    /// Backed by the same locked state file the agent hook failure reporter
    /// uses; a claim error fails closed (skips the capture) like that reporter.
    private func claimThrottledCaptureSlot(stage: String, kind: String) -> Bool {
        let store = ClaudeHookSessionStore(processEnv: processEnv)
        // Bounded lock wait: the CLI is already on an error path, so a
        // contended/stuck state lock must skip the capture (fail closed)
        // instead of blocking the command's exit.
        return (try? store.claimAgentHookFailureReport(
            agentName: "cli-sentry",
            stage: stage,
            sessionId: kind,
            deadline: Date.now.addingTimeInterval(0.25)
        )) == true
    }

    /// Preserves structured CLI error provenance before Sentry bridges the
    /// value to an ``NSError``. The reporting policy must not infer lifecycle
    /// state from localized text when the protocol already supplied a code.
    private func metadata(for error: Error) -> CLIErrorMetadata {
        if let cliError = error as? CLIError {
            return (
                code: cliError.v2Code,
                socketPathMissing: cliError.socketFailureKind == .pathMissing,
                legacyMessage: String(describing: cliError),
                isStructuredProtocolResponse: cliError.isStructuredProtocolResponse
            )
        }

        // A few command helpers wrap failures in NSError. Walk the standard
        // underlying-error chain so the same policy applies after wrapping,
        // while keeping a hard bound against malformed cycles.
        var current: NSError? = error as NSError
        var remaining = 8
        while let candidate = current, remaining > 0 {
            if let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? CLIError {
                return (
                    code: underlying.v2Code,
                    socketPathMissing: underlying.socketFailureKind == .pathMissing,
                    legacyMessage: String(describing: underlying),
                    isStructuredProtocolResponse: underlying.isStructuredProtocolResponse
                )
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            remaining -= 1
        }
        return (
            code: nil,
            socketPathMissing: false,
            legacyMessage: nil,
            isStructuredProtocolResponse: false
        )
    }

#if DEBUG
    private func recordCaptureProbe(stage: String, error: Error) {
        guard let path = processEnv["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return
        }
        let payload = "stage=\(stage)\nerror=\(String(describing: error))\n"
        try? payload.write(toFile: NSString(string: path).expandingTildeInPath, atomically: true, encoding: .utf8)
    }

#if canImport(Sentry)
    private func recordStoreProbe(eventId: String, fingerprint: [String]) {
        guard let path = processEnv["CMUX_CLI_SENTRY_STORE_PROBE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return
        }
        let payload = "event_id=\(eventId)\nfingerprint=\(fingerprint.joined(separator: "|"))\n"
        try? payload.write(toFile: NSString(string: path).expandingTildeInPath, atomically: true, encoding: .utf8)
    }
#endif
#endif

#if canImport(Sentry)
    private static func makeErrorEvent(
        error: Error,
        context: [String: Any],
        command: String,
        subcommand: String,
        fingerprint: [String],
        breadcrumbs: [Breadcrumb]
    ) -> Event {
        let nsError = error as NSError
        let event = Event(error: nsError)
        event.exceptions = errorChain(for: nsError).reversed().map(Self.makeException)
        event.level = .error
        // Every CLI error shares one NSError domain+code with system-only
        // frames, so default grouping folds all failure classes into a single
        // issue. Group by stage plus normalized error kind instead;
        // "{{ default }}" keeps default grouping inside the stage for
        // unclassified errors.
        event.fingerprint = fingerprint
        event.releaseName = currentSentryReleaseName()
#if DEBUG
        event.environment = "development-cli"
#else
        event.environment = "production-cli"
#endif
        event.tags = [
            "component": "cmux-cli",
            "cli_command": command,
            "cli_subcommand": subcommand
        ]
        event.context = ["cli_socket": context]
        if !breadcrumbs.isEmpty {
            event.breadcrumbs = breadcrumbs
        }
        return event
    }

    private static func errorChain(for error: NSError) -> [NSError] {
        var errors = [error]
        var underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = underlying {
            errors.append(current)
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    private static func makeException(for error: NSError) -> Exception {
        let value: String
        if let debugDescription = error.userInfo[NSDebugDescriptionErrorKey] as? String {
            value = "\(debugDescription) (Code: \(error.code))"
        } else {
            value = "Code: \(error.code)"
        }

        let exception = Exception(value: value, type: error.domain)
        let mechanism = Mechanism(type: "NSError")
        let mechanismContext = MechanismContext()
        mechanismContext.error = SentryNSError(domain: error.domain, code: error.code)
        mechanism.meta = mechanismContext
        mechanism.desc = error.description
        mechanism.data = error.userInfo
        exception.mechanism = mechanism
        return exception
    }

    private static func isExpectedCLISocketTransportEvent(
        _ event: Event,
        classificationMessage: String? = nil
    ) -> Bool {
        let noiseFilter = SentryNoiseFilter()
        guard let socketContext = event.context?["cli_socket"] else {
            return false
        }
        let stage = socketContext["stage"] as? String ?? ""
        let contextMessage = socketContext["error"] as? String ?? ""
        let cliErrorCode = socketContext["cli_error_code"] as? String
        let isStructuredProtocolResponse = socketContext["cli_error_protocol_response"] as? Bool ?? false
        let socketPathMissing = socketContext["socket_path_missing"] as? Bool ?? false
        let dataKeys = Set(socketContext.keys)
        let isAgentHookStage = stage.hasPrefix("agent-hook-")
        let hasStructuredCLIErrorCode =
            cliErrorCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if isStructuredProtocolResponse,
           noiseFilter.isExpectedCLIProtocolOutcomeCode(cliErrorCode) {
            return true
        }

        if noiseFilter.isExpectedCLISocketTransportFailure(
            stage: stage,
            message: contextMessage,
            dataKeys: dataKeys,
            cliErrorCode: cliErrorCode,
            socketPathMissing: socketPathMissing
        ) {
            return true
        }

        // A structured actionable code is authoritative. Do not let a legacy
        // message in the rendered event override it.
        guard !hasStructuredCLIErrorCode else { return false }

        var legacyMessages = [String]()
        // Agent-hook originals are intentionally privacy-reduced out of the
        // event. The explicit classification message is available on the
        // synchronous capture path; beforeSend still handles any serialized
        // legacy text without guessing from a wrapper.
        if let classificationMessage {
            legacyMessages.append(classificationMessage)
        }
        if let message = event.message?.formatted {
            legacyMessages.append(message)
        }
        legacyMessages.append(contentsOf: event.exceptions?.compactMap(\.value) ?? [])
        return legacyMessages.contains {
            noiseFilter.isExpectedCLISocketTransportFailure(
                stage: stage,
                message: $0,
                dataKeys: dataKeys
            ) ||
                (isAgentHookStage &&
                    noiseFilter.isExpectedLegacyCLIAppLifecycleMessage($0))
        }
    }

    private func makeBreadcrumb(message: String, data: [String: Any]) -> Breadcrumb {
        var payload = baseContext()
        for (key, value) in data {
            payload[key] = value
        }
        let crumb = Breadcrumb(level: .info, category: "cmux.cli")
        crumb.message = message
        crumb.data = payload
        return crumb
    }
#endif

    private func baseContext() -> [String: Any] {
        var context: [String: Any] = [
            "command": command,
            "subcommand": subcommand,
            "requested_socket_path": socketPath,
            "env_socket_path": envSocketPath ?? "<unset>"
        ]
        if let workspaceId {
            context["workspace_id"] = workspaceId
        }
        if let surfaceId {
            context["surface_id"] = surfaceId
        }
        return context
    }

    private func socketDiagnostics() -> [String: Any] {
        var context: [String: Any] = [
            "cwd": FileManager.default.currentDirectoryPath,
            "uid": Int(getuid()),
            "euid": Int(geteuid())
        ]

        var st = stat()
        if lstat(socketPath, &st) == 0 {
            context["socket_exists"] = true
            context["socket_mode"] = String(format: "%o", Int(st.st_mode & 0o7777))
            context["socket_owner_uid"] = Int(st.st_uid)
            context["socket_owner_gid"] = Int(st.st_gid)
            context["socket_file_type"] = Self.fileTypeDescription(mode: st.st_mode)
        } else {
            let code = errno
            context["socket_exists"] = false
            context["socket_errno"] = Int(code)
            context["socket_errno_description"] = String(cString: strerror(code))
        }

        let tmpSockets = Self.discoverSockets(in: "/tmp", limit: 10)
        if !tmpSockets.isEmpty {
            context["tmp_cmux_sockets"] = tmpSockets
        }
        let taggedSockets = tmpSockets.filter { $0 != CLISocketPathResolver.legacyDefaultSocketPath }
        if CLISocketPathResolver.isImplicitDefaultPath(
            socketPath,
            bundleIdentifier: CLISocketPathResolver.currentAppBundleIdentifier(),
            environment: processEnv
        ),
           (envSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           !taggedSockets.isEmpty {
            context["possible_root_cause"] = "CMUX_SOCKET_PATH missing while tagged sockets exist"
        }

        return context
    }

    private static func fileTypeDescription(mode: mode_t) -> String {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFSOCK):
            return "socket"
        case mode_t(S_IFREG):
            return "regular"
        case mode_t(S_IFDIR):
            return "directory"
        case mode_t(S_IFLNK):
            return "symlink"
        default:
            return "other"
        }
    }

    private static func discoverSockets(in directory: String, limit: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var sockets: [String] = []
        for name in entries.sorted() {
            guard name.hasPrefix("cmux"), name.hasSuffix(".sock") else { continue }
            let fullPath = URL(fileURLWithPath: directory)
                .appendingPathComponent(name, isDirectory: false)
                .path
            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
            sockets.append(fullPath)
            if sockets.count >= limit {
                break
            }
        }
        return sockets
    }

#if canImport(Sentry)
    private static func ensureStarted() {
        startupLock.lock()
        defer { startupLock.unlock() }
        guard !started else { return }
        SentrySDK.start { options in
            CLISentryRuntimePolicy().configure(options)
            options.dsn = dsn
            options.releaseName = currentSentryReleaseName()
#if DEBUG
            options.environment = "development-cli"
#else
            options.environment = "production-cli"
#endif
            options.debug = false
            // Defense-in-depth: keep default PII (user, IP, etc.) off the wire.
            // The scrubber below additionally redacts any user fields that slip in.
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.tracesSampleRate = 0.0
            options.enableCaptureFailedRequests = false
            // Redact file paths, emails, and secrets from every outgoing event
            // and breadcrumb before it leaves the device.
            let scrubber = SentryEventScrubber()
            options.beforeSend = { event in
                if Self.isExpectedCLISocketTransportEvent(event) {
                    return nil
                }
                return scrubber.scrub(event)
            }
            options.beforeBreadcrumb = { breadcrumb in scrubber.scrub(breadcrumb) }
        }
        started = true
    }
#endif
}
