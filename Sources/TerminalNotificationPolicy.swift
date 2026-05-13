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
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let outputBuffer = NotificationHookPipeBuffer()
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>, Never>?
    private var didComplete = false
    private var didTimeout = false

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
            storeContinuation(continuation)
            configureProcess()
            installPipeHandlers()

            process.terminationHandler = { [weak self] process in
                self?.finish(terminationStatus: process.terminationStatus)
            }

            do {
                try process.run()
                stdinPipe.fileHandleForWriting.write(inputData)
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                complete(.failure(TerminalNotificationPolicyEngine.failure(
                    hook: hook,
                    message: "Could not launch notification hook: \(error.localizedDescription)"
                )))
                return
            }

            Task { [weak self] in
                await self?.enforceTimeout()
            }
        }
    }

    private func storeContinuation(
        _ continuation: CheckedContinuation<Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>, Never>
    ) {
        stateLock.lock()
        self.continuation = continuation
        stateLock.unlock()
    }

    private func configureProcess() {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", hook.command]
        process.currentDirectoryURL = URL(fileURLWithPath: hook.cwd, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["CMUX_NOTIFICATION_TITLE"] = envelope.notification.title
        env["CMUX_NOTIFICATION_SUBTITLE"] = envelope.notification.subtitle
        env["CMUX_NOTIFICATION_BODY"] = envelope.notification.body
        env["CMUX_NOTIFICATION_WORKSPACE_ID"] = envelope.notification.workspaceId
        env["CMUX_NOTIFICATION_SURFACE_ID"] = envelope.notification.surfaceId ?? ""
        env["CMUX_NOTIFICATION_POLICY_JSON"] = String(data: inputData, encoding: .utf8) ?? ""
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    private func installPipeHandlers() {
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        makeNonBlocking(stdoutHandle.fileDescriptor)
        makeNonBlocking(stderrHandle.fileDescriptor)

        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.drain(fileDescriptor: handle.fileDescriptor, stream: .stdout)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.drain(fileDescriptor: handle.fileDescriptor, stream: .stderr)
        }
    }

    private func makeNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private func enforceTimeout() async {
        let nanoseconds = timeoutNanoseconds(for: hook.timeoutSeconds)
        try? await Task.sleep(nanoseconds: nanoseconds)
        guard markTimedOutIfNeeded() else { return }

        if process.isRunning {
            process.terminate()
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func timeoutNanoseconds(for seconds: TimeInterval) -> UInt64 {
        let maxSeconds = TimeInterval(UInt64.max / 1_000_000_000)
        let clamped = min(seconds, maxSeconds)
        return UInt64(clamped * 1_000_000_000)
    }

    private func markTimedOutIfNeeded() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didComplete else { return false }
        didTimeout = true
        return true
    }

    private func finish(terminationStatus: Int32) {
        drain(fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor, stream: .stdout)
        drain(fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor, stream: .stderr)

        let timedOut = stateLock.withLockedValue { didTimeout }
        if timedOut {
            complete(.failure(TerminalNotificationPolicyEngine.failure(
                hook: hook,
                message: "Notification hook timed out after \(Int(hook.timeoutSeconds))s"
            )))
            return
        }

        let output = outputBuffer.snapshot()
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
            let decoded = try JSONDecoder().decode(TerminalNotificationPolicyEnvelope.self, from: outputData)
            complete(.success(decoded))
        } catch {
            complete(.failure(TerminalNotificationPolicyEngine.failure(
                hook: hook,
                message: "Notification hook returned invalid JSON: \(error.localizedDescription)"
            )))
        }
    }

    private func drain(fileDescriptor: Int32, stream: NotificationHookOutputStream) {
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

            if readCount == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            if errno == EINTR {
                continue
            }
            return
        }
    }

    private func complete(
        _ result: Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>
    ) {
        let continuation: CheckedContinuation<Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>, Never>?
        stateLock.lock()
        if didComplete {
            stateLock.unlock()
            return
        }
        didComplete = true
        continuation = self.continuation
        self.continuation = nil
        stateLock.unlock()

        cleanup()
        continuation?.resume(returning: result)
    }

    private func cleanup() {
        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
        stdinPipe.fileHandleForWriting.closeFile()
    }
}

private extension NSLock {
    func withLockedValue<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
