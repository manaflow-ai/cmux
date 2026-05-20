import AppKit
import Darwin
import Foundation

struct TerminalNotificationPolicyPayload: Codable, Sendable, Equatable {
    var workspaceId: String
    var surfaceId: String?
    var title: String
    var subtitle: String
    var body: String
}

struct TerminalNotificationPolicyContext: Codable, Sendable, Equatable {
    var cwd: String?
    var configPath: String?
    var hookId: String?
    var appFocused: Bool
    var focusedPanel: Bool
}

struct TerminalNotificationPolicyEffects: Codable, Sendable, Equatable {
    var record: Bool = true
    var markUnread: Bool = true
    var reorderWorkspace: Bool = true
    var desktop: Bool = true
    var sound: Bool = true
    var command: Bool = true
    var paneFlash: Bool = true

    private enum CodingKeys: String, CodingKey {
        case record
        case markUnread
        case reorderWorkspace
        case desktop
        case sound
        case command
        case paneFlash
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        record = try container.decodeIfPresent(Bool.self, forKey: .record) ?? true
        markUnread = try container.decodeIfPresent(Bool.self, forKey: .markUnread) ?? true
        reorderWorkspace = try container.decodeIfPresent(Bool.self, forKey: .reorderWorkspace) ?? true
        desktop = try container.decodeIfPresent(Bool.self, forKey: .desktop) ?? true
        sound = try container.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? true
        paneFlash = try container.decodeIfPresent(Bool.self, forKey: .paneFlash) ?? true
    }
}

private struct TerminalNotificationPolicyEffectsPatch: Decodable {
    var record: Bool?
    var markUnread: Bool?
    var reorderWorkspace: Bool?
    var desktop: Bool?
    var sound: Bool?
    var command: Bool?
    var paneFlash: Bool?

    func merged(into effects: TerminalNotificationPolicyEffects) -> TerminalNotificationPolicyEffects {
        var merged = effects
        if let record {
            merged.record = record
        }
        if let markUnread {
            merged.markUnread = markUnread
        }
        if let reorderWorkspace {
            merged.reorderWorkspace = reorderWorkspace
        }
        if let desktop {
            merged.desktop = desktop
        }
        if let sound {
            merged.sound = sound
        }
        if let command {
            merged.command = command
        }
        if let paneFlash {
            merged.paneFlash = paneFlash
        }
        return merged
    }
}

private struct TerminalNotificationPolicyPayloadPatch: Decodable {
    var workspaceId: String?
    var surfaceId: String??
    var title: String?
    var subtitle: String?
    var body: String?

    private enum CodingKeys: String, CodingKey {
        case workspaceId
        case surfaceId
        case title
        case subtitle
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try container.decodeIfNonNullValuePresent(String.self, forKey: .workspaceId)
        surfaceId = try container.decodeNullableValueIfPresent(String.self, forKey: .surfaceId)
        title = try container.decodeIfNonNullValuePresent(String.self, forKey: .title)
        subtitle = try container.decodeIfNonNullValuePresent(String.self, forKey: .subtitle)
        body = try container.decodeIfNonNullValuePresent(String.self, forKey: .body)
    }

    func merged(into payload: TerminalNotificationPolicyPayload) -> TerminalNotificationPolicyPayload {
        var merged = payload
        if let workspaceId {
            merged.workspaceId = workspaceId
        }
        if let surfaceId {
            merged.surfaceId = surfaceId
        }
        if let title {
            merged.title = title
        }
        if let subtitle {
            merged.subtitle = subtitle
        }
        if let body {
            merged.body = body
        }
        return merged
    }
}

private struct TerminalNotificationPolicyContextPatch: Decodable {
    var cwd: String??
    var configPath: String??
    var hookId: String??
    var appFocused: Bool?
    var focusedPanel: Bool?

    private enum CodingKeys: String, CodingKey {
        case cwd
        case configPath
        case hookId
        case appFocused
        case focusedPanel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeNullableValueIfPresent(String.self, forKey: .cwd)
        configPath = try container.decodeNullableValueIfPresent(String.self, forKey: .configPath)
        hookId = try container.decodeNullableValueIfPresent(String.self, forKey: .hookId)
        appFocused = try container.decodeIfNonNullValuePresent(Bool.self, forKey: .appFocused)
        focusedPanel = try container.decodeIfNonNullValuePresent(Bool.self, forKey: .focusedPanel)
    }

    func merged(into context: TerminalNotificationPolicyContext) -> TerminalNotificationPolicyContext {
        var merged = context
        if let cwd {
            merged.cwd = cwd
        }
        if let configPath {
            merged.configPath = configPath
        }
        if let hookId {
            merged.hookId = hookId
        }
        if let appFocused {
            merged.appFocused = appFocused
        }
        if let focusedPanel {
            merged.focusedPanel = focusedPanel
        }
        return merged
    }
}

struct TerminalNotificationPolicyEnvelope: Codable, Sendable, Equatable {
    var version: Int = 1
    var notification: TerminalNotificationPolicyPayload
    var context: TerminalNotificationPolicyContext
    var effects: TerminalNotificationPolicyEffects = TerminalNotificationPolicyEffects()
    var stop: Bool?
}

struct TerminalNotificationPolicyRequest: Sendable {
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let cwd: String?
    let isAppFocused: Bool
    let isFocusedPanel: Bool
}

struct TerminalNotificationPolicyFailure: Error, Sendable, Hashable {
    let hookId: String
    let sourcePath: String?
    let message: String
}

enum TerminalNotificationPolicyEngine {
    private static let maxOutputBytes = 1_048_576

    static func evaluate(
        request: TerminalNotificationPolicyRequest,
        hooks: [CmuxResolvedNotificationHook]
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        let initialEnvelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: request.tabId.uuidString,
                surfaceId: request.surfaceId?.uuidString,
                title: request.title,
                subtitle: request.subtitle,
                body: request.body
            ),
            context: TerminalNotificationPolicyContext(
                cwd: request.cwd,
                configPath: nil,
                hookId: nil,
                appFocused: request.isAppFocused,
                focusedPanel: request.isFocusedPanel
            )
        )

        return await evaluate(envelope: initialEnvelope, hooks: hooks)
    }

    static func evaluate(
        envelope initialEnvelope: TerminalNotificationPolicyEnvelope,
        hooks: [CmuxResolvedNotificationHook]
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        guard !hooks.isEmpty else {
            return .success(initialEnvelope)
        }

        var envelope = initialEnvelope
        for hook in hooks {
            envelope.context.cwd = hook.cwd
            envelope.context.configPath = hook.sourcePath
            envelope.context.hookId = hook.id
            switch await run(hook: hook, envelope: envelope) {
            case .success(let nextEnvelope):
                envelope = nextEnvelope
                if envelope.stop == true {
                    return .success(envelope)
                }
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .success(envelope)
    }

    private static func run(
        hook: CmuxResolvedNotificationHook,
        envelope: TerminalNotificationPolicyEnvelope
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        let inputData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            inputData = try encoder.encode(envelope)
        } catch {
            return .failure(failure(hook: hook, message: "Could not encode notification policy input: \(error.localizedDescription)"))
        }

        return await NotificationHookProcessRun(
            hook: hook,
            envelope: envelope,
            inputData: inputData,
            maxOutputBytes: maxOutputBytes
        ).run()
    }

    fileprivate static func failure(
        hook: CmuxResolvedNotificationHook,
        message: String
    ) -> TerminalNotificationPolicyFailure {
        TerminalNotificationPolicyFailure(
            hookId: hook.id,
            sourcePath: hook.sourcePath,
            message: message
        )
    }
}

@MainActor
enum NotificationPolicyHookAuthorizer {
    static func authorize(
        _ hooks: [CmuxResolvedNotificationHook],
        globalConfigPath: String?,
        presentingWindow: NSWindow? = nil
    ) async -> [CmuxResolvedNotificationHook] {
        var authorizedHooks: [CmuxResolvedNotificationHook] = []
        let resolvedPresentingWindow = presentingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow

        for hook in hooks {
            guard let descriptor = hook.trustDescriptor else {
                authorizedHooks.append(hook)
                continue
            }
            guard !CmuxActionTrust.shared.isTrusted(descriptor) else {
                authorizedHooks.append(hook)
                continue
            }
            guard let globalConfigPath else {
                continue
            }

            let isAuthorized = await authorizeHook(
                hook,
                descriptor: descriptor,
                globalConfigPath: globalConfigPath,
                presentingWindow: resolvedPresentingWindow
            )
            if isAuthorized {
                authorizedHooks.append(hook)
            }
        }

        return authorizedHooks
    }

    private static func authorizeHook(
        _ hook: CmuxResolvedNotificationHook,
        descriptor: CmuxActionTrustDescriptor,
        globalConfigPath: String,
        presentingWindow: NSWindow?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            CmuxConfigExecutor.authorizeProjectAutomationIfNeeded(
                descriptor: descriptor,
                confirm: false,
                configSourcePath: hook.sourcePath,
                globalConfigPath: globalConfigPath,
                displayCommand: "[\(hook.id)] \(hook.command)",
                presentingWindow: presentingWindow
            ) {
                continuation.resume(returning: true)
            } onDenied: {
                continuation.resume(returning: false)
            }
        }
    }
}

private enum NotificationHookOutputStream {
    case stdout
    case stderr
}

private final class NotificationHookPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutExceededLimit = false
    private let maxStderrBytes = 65_536

    func append(
        _ bytes: UnsafeBufferPointer<UInt8>,
        stream: NotificationHookOutputStream,
        maxOutputBytes: Int
    ) {
        guard let baseAddress = bytes.baseAddress, bytes.count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout:
            let remaining = max(0, maxOutputBytes - stdoutData.count)
            if bytes.count > remaining {
                stdoutExceededLimit = true
            }
            if remaining > 0 {
                stdoutData.append(baseAddress, count: min(bytes.count, remaining))
            }
        case .stderr:
            let remaining = max(0, maxStderrBytes - stderrData.count)
            if remaining > 0 {
                stderrData.append(baseAddress, count: min(bytes.count, remaining))
            }
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data, stdoutExceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData, stdoutExceededLimit)
    }
}

private final class NotificationHookProcessRun: @unchecked Sendable {
    private let hook: CmuxResolvedNotificationHook
    private let envelope: TerminalNotificationPolicyEnvelope
    private let inputData: Data
    private let maxOutputBytes: Int
    private let queue = DispatchQueue(
        label: "com.cmuxterm.notification-hook.process.\(UUID().uuidString)",
        qos: .utility
    )
    private let stdinWriteQueue = DispatchQueue(
        label: "com.cmuxterm.notification-hook.stdin.\(UUID().uuidString)",
        qos: .utility
    )
    private let outputBuffer = NotificationHookPipeBuffer()
    private var continuation: CheckedContinuation<Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>, Never>?
    private var processId: pid_t = -1
    private var stdinWriteFD: Int32 = -1
    private var stdoutReadFD: Int32 = -1
    private var stderrReadFD: Int32 = -1
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private var timeoutSource: DispatchSourceTimer?
    private var killSource: DispatchSourceTimer?
    private var didComplete = false
    private var didRequestTermination = false
    private var pendingFailure: TerminalNotificationPolicyFailure?

    init(
        hook: CmuxResolvedNotificationHook,
        envelope: TerminalNotificationPolicyEnvelope,
        inputData: Data,
        maxOutputBytes: Int
    ) {
        self.hook = hook
        self.envelope = envelope
        self.inputData = inputData
        self.maxOutputBytes = maxOutputBytes
    }

    func run() async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                self.start()
            }
        }
    }

    private func start() {
        do {
            try spawnHook()
            installReadSources()
            installWaitSource()
            installTimeoutSource()
            writeInputAndCloseStdin()
        } catch {
            closeOpenFileDescriptors()
            complete(.failure(TerminalNotificationPolicyEngine.failure(
                hook: hook,
                message: "Could not launch notification hook: \(error.localizedDescription)"
            )))
        }
    }

    private func spawnHook() throws {
        var stdinFDs = [Int32](repeating: -1, count: 2)
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        defer {
            for fileDescriptor in stdinFDs + stdoutFDs + stderrFDs where fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }
        try throwIfPOSIXError(pipe(&stdinFDs), operation: "create stdin pipe")
        try throwIfPOSIXError(pipe(&stdoutFDs), operation: "create stdout pipe")
        try throwIfPOSIXError(pipe(&stderrFDs), operation: "create stderr pipe")

        var fileActions: posix_spawn_file_actions_t?
        try throwIfPOSIXError(posix_spawn_file_actions_init(&fileActions), operation: "initialize spawn file actions")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try hook.cwd.withCString { cwd in
            try throwIfPOSIXError(
                posix_spawn_file_actions_addchdir_np(&fileActions, cwd),
                operation: "set hook working directory"
            )
        }
        try addDup2(&fileActions, from: stdinFDs[0], to: STDIN_FILENO)
        try addDup2(&fileActions, from: stdoutFDs[1], to: STDOUT_FILENO)
        try addDup2(&fileActions, from: stderrFDs[1], to: STDERR_FILENO)
        for fileDescriptor in stdinFDs + stdoutFDs + stderrFDs {
            try throwIfPOSIXError(
                posix_spawn_file_actions_addclose(&fileActions, fileDescriptor),
                operation: "close inherited hook pipe"
            )
        }

        var attributes: posix_spawnattr_t?
        try throwIfPOSIXError(posix_spawnattr_init(&attributes), operation: "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        try throwIfPOSIXError(posix_spawnattr_setflags(&attributes, flags), operation: "set spawn flags")
        try throwIfPOSIXError(posix_spawnattr_setpgroup(&attributes, 0), operation: "set process group")

        let arguments = ["/bin/sh", "-c", hook.command]
        let environment = environmentStrings()
        var spawnedPID: pid_t = 0
        let spawnResult = withCStringArray(arguments) { argv in
            withCStringArray(environment) { envp in
                "/bin/sh".withCString { executablePath in
                    posix_spawn(&spawnedPID, executablePath, &fileActions, &attributes, argv, envp)
                }
            }
        }
        try throwIfPOSIXError(spawnResult, operation: "spawn notification hook")

        processId = spawnedPID
        stdinWriteFD = stdinFDs[1]
        stdoutReadFD = stdoutFDs[0]
        stderrReadFD = stderrFDs[0]
        stdinFDs[1] = -1
        stdoutFDs[0] = -1
        stderrFDs[0] = -1
        close(stdinFDs[0])
        stdinFDs[0] = -1
        close(stdoutFDs[1])
        stdoutFDs[1] = -1
        close(stderrFDs[1])
        stderrFDs[1] = -1
        makeNonBlocking(stdoutReadFD)
        makeNonBlocking(stderrReadFD)
    }

    private func environmentStrings() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["CMUX_NOTIFICATION_TITLE"] = envelope.notification.title
        env["CMUX_NOTIFICATION_SUBTITLE"] = envelope.notification.subtitle
        env["CMUX_NOTIFICATION_BODY"] = envelope.notification.body
        env["CMUX_NOTIFICATION_WORKSPACE_ID"] = envelope.notification.workspaceId
        env["CMUX_NOTIFICATION_SURFACE_ID"] = envelope.notification.surfaceId ?? ""
        env["CMUX_NOTIFICATION_POLICY_JSON"] = String(data: inputData, encoding: .utf8) ?? ""
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func addDup2(
        _ fileActions: inout posix_spawn_file_actions_t?,
        from source: Int32,
        to destination: Int32
    ) throws {
        try throwIfPOSIXError(
            posix_spawn_file_actions_adddup2(&fileActions, source, destination),
            operation: "configure hook pipe"
        )
    }

    private func throwIfPOSIXError(_ result: Int32, operation: String) throws {
        guard result != 0 else { return }
        throw POSIXError(.init(rawValue: result) ?? .EIO)
    }

    private func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for cString in cStrings {
                free(cString)
            }
        }
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private func makeNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private func installReadSources() {
        stdoutSource = makeReadSource(fileDescriptor: stdoutReadFD, stream: .stdout)
        stderrSource = makeReadSource(fileDescriptor: stderrReadFD, stream: .stderr)
    }

    private func makeReadSource(
        fileDescriptor: Int32,
        stream: NotificationHookOutputStream
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [self] in
            let reachedEOF = self.drain(fileDescriptor: fileDescriptor, stream: stream)
            if reachedEOF {
                self.cancelReadSource(for: stream)
            }
            if self.outputBuffer.snapshot().stdoutExceededLimit {
                self.requestTermination(TerminalNotificationPolicyEngine.failure(
                    hook: self.hook,
                    message: "Notification hook output exceeded \(self.maxOutputBytes) bytes"
                ))
            }
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        return source
    }

    private func installWaitSource() {
        let source = DispatchSource.makeProcessSource(
            identifier: processId,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [self] in
            self.processExited()
        }
        waitSource = source
        source.resume()
    }

    private func installTimeoutSource() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + hook.timeoutSeconds)
        source.setEventHandler { [self] in
            self.timeoutReached()
        }
        timeoutSource = source
        source.resume()
    }

    private func writeInputAndCloseStdin() {
        guard stdinWriteFD >= 0 else { return }
        let fileDescriptor = stdinWriteFD
        let dataToWrite = inputData
        stdinWriteFD = -1
        stdinWriteQueue.async {
            dataToWrite.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < dataToWrite.count {
                    let written = write(fileDescriptor, baseAddress.advanced(by: offset), dataToWrite.count - offset)
                    if written > 0 {
                        offset += Int(written)
                        continue
                    }
                    if written == -1 && errno == EINTR {
                        continue
                    }
                    break
                }
            }
            close(fileDescriptor)
        }
    }

    private func timeoutReached() {
        guard !didComplete else { return }
        if let status = reapProcessIfExited() {
            finish(rawStatus: status)
            return
        }
        requestTermination(TerminalNotificationPolicyEngine.failure(
            hook: hook,
            message: "Notification hook timed out after \(Int(hook.timeoutSeconds))s"
        ))
    }

    private func requestTermination(_ failure: TerminalNotificationPolicyFailure) {
        guard !didComplete else { return }
        if pendingFailure == nil {
            pendingFailure = failure
        }
        guard !didRequestTermination else { return }
        didRequestTermination = true
        signalProcessGroup(SIGTERM)
        scheduleKillAfterGracePeriod()
    }

    private func scheduleKillAfterGracePeriod() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(750))
        source.setEventHandler { [self] in
            if self.processId > 0 {
                self.signalProcessGroup(SIGKILL)
            }
            self.killSource?.cancel()
            self.killSource = nil
        }
        killSource = source
        source.resume()
    }

    private func signalProcessGroup(_ signal: Int32) {
        guard processId > 0 else { return }
        if kill(-processId, signal) != 0 {
            kill(processId, signal)
        }
    }

    private func processExited() {
        guard let status = waitForProcessExit() else { return }
        finish(rawStatus: status)
    }

    private func reapProcessIfExited() -> Int32? {
        guard processId > 0 else { return nil }
        var status: Int32 = 0
        let result = waitpid(processId, &status, WNOHANG)
        if result == processId {
            processId = -1
            return status
        }
        if result == -1 && errno == ECHILD {
            processId = -1
            return 0
        }
        return nil
    }

    private func waitForProcessExit() -> Int32? {
        guard processId > 0 else { return nil }
        var status: Int32 = 0
        while true {
            let result = waitpid(processId, &status, 0)
            if result == processId {
                processId = -1
                return status
            }
            if result == -1 && errno == EINTR {
                continue
            }
            if result == -1 && errno == ECHILD {
                processId = -1
                return 0
            }
            return nil
        }
    }

    private func finish(rawStatus: Int32) {
        if stdoutReadFD >= 0 {
            drain(fileDescriptor: stdoutReadFD, stream: .stdout)
        }
        if stderrReadFD >= 0 {
            drain(fileDescriptor: stderrReadFD, stream: .stderr)
        }

        if let pendingFailure {
            complete(.failure(pendingFailure))
            return
        }

        let output = outputBuffer.snapshot()
        let terminationStatus = normalizedTerminationStatus(rawStatus)
        if terminationStatus != 0 {
            let detail = String(data: output.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            complete(.failure(TerminalNotificationPolicyEngine.failure(
                hook: hook,
                message: "Notification hook exited with status \(terminationStatus)\(detail.map { ": \($0)" } ?? "")"
            )))
            return
        }

        if output.stdoutExceededLimit {
            complete(.failure(TerminalNotificationPolicyEngine.failure(
                hook: hook,
                message: "Notification hook output exceeded \(maxOutputBytes) bytes"
            )))
            return
        }

        guard let outputString = String(data: output.stdout, encoding: .utf8) else {
            complete(.failure(TerminalNotificationPolicyEngine.failure(
                hook: hook,
                message: "Notification hook returned non-UTF-8 output"
            )))
            return
        }
        let trimmedOutput = outputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            complete(.success(envelope))
            return
        }
        let outputData = Data(trimmedOutput.utf8)
        do {
            let patch = try JSONDecoder().decode(TerminalNotificationPolicyEnvelopePatch.self, from: outputData)
            complete(.success(patch.merged(into: envelope)))
        } catch {
            complete(.failure(TerminalNotificationPolicyEngine.failure(
                hook: hook,
                message: "Notification hook returned invalid JSON: \(error.localizedDescription)"
            )))
        }
    }

    private func normalizedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal != 0 {
            return 128 + signal
        }
        return (rawStatus >> 8) & 0xff
    }

    @discardableResult
    private func drain(fileDescriptor: Int32, stream: NotificationHookOutputStream) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let readCount = read(fileDescriptor, &bytes, bytes.count)
            if readCount > 0 {
                let byteCount = Int(readCount)
                bytes.withUnsafeBufferPointer { buffer in
                    let chunk = UnsafeBufferPointer(start: buffer.baseAddress, count: byteCount)
                    outputBuffer.append(chunk, stream: stream, maxOutputBytes: maxOutputBytes)
                }
                continue
            }

            if readCount == 0 {
                return true
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            }
            if errno == EINTR {
                continue
            }
            return false
        }
    }

    private func complete(
        _ result: Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>
    ) {
        let continuation: CheckedContinuation<Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>, Never>?
        if didComplete {
            return
        }
        didComplete = true
        continuation = self.continuation
        self.continuation = nil

        cleanup()
        continuation?.resume(returning: result)
    }

    private func cleanup() {
        timeoutSource?.cancel()
        timeoutSource = nil
        killSource?.cancel()
        killSource = nil
        waitSource?.cancel()
        waitSource = nil
        cancelReadSource(for: .stdout)
        cancelReadSource(for: .stderr)
        closeAndInvalidate(&stdinWriteFD)
        closeOpenFileDescriptors()
    }

    private func cancelReadSource(for stream: NotificationHookOutputStream) {
        switch stream {
        case .stdout:
            stdoutSource?.cancel()
            stdoutSource = nil
            stdoutReadFD = -1
        case .stderr:
            stderrSource?.cancel()
            stderrSource = nil
            stderrReadFD = -1
        }
    }

    private func closeOpenFileDescriptors() {
        closeAndInvalidate(&stdinWriteFD)
        if stdoutSource == nil {
            closeAndInvalidate(&stdoutReadFD)
        }
        if stderrSource == nil {
            closeAndInvalidate(&stderrReadFD)
        }
    }

    private func closeAndInvalidate(_ fileDescriptor: inout Int32) {
        guard fileDescriptor >= 0 else { return }
        close(fileDescriptor)
        fileDescriptor = -1
    }
}

private struct TerminalNotificationPolicyEnvelopePatch: Decodable {
    var version: Int?
    var notification: TerminalNotificationPolicyPayloadPatch?
    var context: TerminalNotificationPolicyContextPatch?
    var effects: TerminalNotificationPolicyEffectsPatch?
    var stop: Bool?

    func merged(into envelope: TerminalNotificationPolicyEnvelope) -> TerminalNotificationPolicyEnvelope {
        TerminalNotificationPolicyEnvelope(
            version: version ?? envelope.version,
            notification: notification?.merged(into: envelope.notification) ?? envelope.notification,
            context: context?.merged(into: envelope.context) ?? envelope.context,
            effects: effects?.merged(into: envelope.effects) ?? envelope.effects,
            stop: stop ?? envelope.stop
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeIfNonNullValuePresent<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeNullableValueIfPresent<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T?? {
        guard contains(key) else { return nil }
        return try decode(T?.self, forKey: key)
    }
}
