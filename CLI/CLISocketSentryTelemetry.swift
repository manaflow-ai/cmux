import CmuxFoundation
import CmuxSentryReporting
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
    private var pendingBreadcrumbs: [PendingBreadcrumb] = []

#if canImport(Sentry)
    private static let startupLock = NSLock()
    private static var started = false
    private static let dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"

    private static func currentSentryReleaseName() -> String? {
        guard let bundleIdentifier = currentSentryBundleIdentifier(),
              let version = currentBundleVersionValue(forKey: "CFBundleShortVersionString"),
              let build = currentBundleVersionValue(forKey: "CFBundleVersion")
        else {
            return nil
        }
        return "\(bundleIdentifier)@\(version)+\(build)"
    }

    private static func currentSentryBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"]?
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
#endif

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
        guard shouldEmit else { return }
        let errorDescription = String(describing: error)
        let classificationCandidate = classificationError ?? error
        let cliErrorMetadata = metadata(for: classificationCandidate)
        let dataKeys = Set(data.keys)
        let isAgentHookStage = stage.hasPrefix("agent-hook-")
        let isExpectedStructuredCLIError =
            noiseFilter.isExpectedCLISocketTransportFailure(
                stage: stage,
                message: errorDescription,
                dataKeys: dataKeys,
                cliErrorCode: cliErrorMetadata.code,
                socketPathMissing: cliErrorMetadata.socketPathMissing
            ) ||
            (isAgentHookStage &&
                (noiseFilter.isExpectedCLIErrorCode(cliErrorMetadata.code) ||
                    cliErrorMetadata.socketPathMissing))
        let hasStructuredCLIErrorCode = cliErrorMetadata.code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let isExpectedLegacyCLIError: Bool
        if !hasStructuredCLIErrorCode, let legacyMessage = cliErrorMetadata.legacyMessage {
            isExpectedLegacyCLIError =
                noiseFilter.isExpectedCLISocketTransportFailure(
                    stage: stage,
                    message: legacyMessage,
                    dataKeys: dataKeys,
                    allowSandboxPolicyDenial: sentryPolicy.allowsSandboxPolicyDenial
                ) ||
                (isAgentHookStage &&
                    noiseFilter.isExpectedLegacyCLIAppLifecycleMessage(legacyMessage))
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
        guard !isExpectedStructuredCLIError,
              !isExpectedLegacyCLIError,
              !isExpectedTransportFailure else {
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
            breadcrumbs: pendingBreadcrumbs.map { pending in
                makeBreadcrumb(message: pending.message, data: pending.data)
            }
        )
        pendingBreadcrumbs.removeAll()
        let scrubber = SentryEventScrubber()
        let scrubbedEvent = scrubber.scrub(event)
        guard !Self.isExpectedCLISocketTransportEvent(scrubbedEvent) else {
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
        recordStoreProbe(eventId: scrubbedEvent.eventId.sentryIdString)
#endif
#endif
    }

    private var shouldEmit: Bool {
        !disabledByEnv
    }

    /// Preserves structured CLI error provenance before Sentry bridges the
    /// value to an ``NSError``. The reporting policy must not infer lifecycle
    /// state from localized text when the protocol already supplied a code.
    private func metadata(for error: Error) -> (
        code: String?,
        socketPathMissing: Bool,
        legacyMessage: String?
    ) {
        if let cliError = error as? CLIError {
            return (
                code: cliError.v2Code,
                socketPathMissing: cliError.socketFailureKind == .pathMissing,
                legacyMessage: String(describing: cliError)
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
                    legacyMessage: String(describing: underlying)
                )
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            remaining -= 1
        }
        return (code: nil, socketPathMissing: false, legacyMessage: nil)
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
    private func recordStoreProbe(eventId: String) {
        guard let path = processEnv["CMUX_CLI_SENTRY_STORE_PROBE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return
        }
        let payload = "event_id=\(eventId)\n"
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
        breadcrumbs: [Breadcrumb]
    ) -> Event {
        let nsError = error as NSError
        let event = Event(error: nsError)
        event.exceptions = errorChain(for: nsError).reversed().map(Self.makeException)
        event.level = .error
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

    private static func isExpectedCLISocketTransportEvent(_ event: Event) -> Bool {
        let noiseFilter = SentryNoiseFilter()
        guard let socketContext = event.context?["cli_socket"] else {
            return false
        }
        let stage = socketContext["stage"] as? String ?? ""
        let contextMessage = socketContext["error"] as? String ?? ""
        let cliErrorCode = socketContext["cli_error_code"] as? String
        let socketPathMissing = socketContext["socket_path_missing"] as? Bool ?? false
        let dataKeys = Set(socketContext.keys)
        let isAgentHookStage = stage.hasPrefix("agent-hook-")
        let hasStructuredCLIErrorCode =
            cliErrorCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if noiseFilter.isExpectedCLISocketTransportFailure(
            stage: stage,
            message: contextMessage,
            dataKeys: dataKeys,
            cliErrorCode: cliErrorCode,
            socketPathMissing: socketPathMissing
        ) ||
            (isAgentHookStage &&
                (noiseFilter.isExpectedCLIErrorCode(cliErrorCode) || socketPathMissing)) {
            return true
        }

        // A structured actionable code is authoritative. Do not let a legacy
        // message in the rendered event override it.
        guard !hasStructuredCLIErrorCode else { return false }

        var legacyMessages = [String]()
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
