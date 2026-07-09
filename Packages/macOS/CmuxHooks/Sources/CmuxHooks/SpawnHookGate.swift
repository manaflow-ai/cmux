import Foundation

/// Evaluates configured blocking pre-spawn hooks.
public actor SpawnHookGate {
    private static let stdoutLimitBytes = 1_048_576
    private let configState: @Sendable () -> CmuxHooksConfigState
    private let runner: any HookProcessRunning
    private let log: @Sendable (String) -> Void

    /// Creates a pre-spawn hook gate.
    /// - Parameters:
    ///   - configState: Synchronous snapshot provider for the current hooks config.
    ///   - runner: Hook process runner.
    ///   - log: Diagnostic logger.
    public init(
        configState: @escaping @Sendable () -> CmuxHooksConfigState,
        runner: any HookProcessRunning,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.configState = configState
        self.runner = runner
        self.log = log
    }

    /// Evaluates one pending spawn.
    /// - Parameter request: The pending spawn request.
    /// - Returns: A proceed grant or a denial reason.
    public func evaluate(_ request: SpawnHookRequest) async -> SpawnHookGateOutcome {
        switch configState() {
        case .absent:
            return .proceed(echoGrant(for: request))
        case .broken(let reason):
            return .deny(reason: "hooks configuration is invalid: \(reason)")
        case .loaded(let config):
            guard let hook = config.preSpawn, hook.enabled else {
                return .proceed(echoGrant(for: request))
            }
            return await evaluate(request, with: hook)
        }
    }

    private func evaluate(_ request: SpawnHookRequest, with hook: CmuxHookDefinition) async -> SpawnHookGateOutcome {
        let stdin: Data
        do {
            stdin = try request.envelopeJSON()
        } catch {
            return .deny(reason: "failed to encode pre-spawn hook request: \(error)")
        }
        let result = await runner.run(
            command: hook.command,
            arguments: hook.args,
            stdin: stdin,
            timeout: .milliseconds(hook.timeoutMs)
        )
        if let launchFailure = result.launchFailure {
            log("pre-spawn hook launch failed: \(launchFailure)")
            return .deny(reason: "pre-spawn hook launch failed: \(launchFailure)")
        }
        if result.timedOut {
            log("pre-spawn hook timed out")
            return .deny(reason: "pre-spawn hook timed out")
        }
        if result.stdout.count > Self.stdoutLimitBytes {
            log("pre-spawn hook stdout exceeded \(Self.stdoutLimitBytes) bytes")
            return .deny(reason: "pre-spawn hook stdout exceeded limit")
        }
        guard result.exitStatus == 0 else {
            let status = result.exitStatus.map(String.init) ?? "unknown"
            log("pre-spawn hook exited non-zero: \(status)")
            return .deny(reason: "pre-spawn hook exited non-zero: \(status)")
        }
        do {
            let decision = try JSONDecoder().decode(SpawnHookDecision.self, from: result.stdout)
            return outcome(for: decision, request: request)
        } catch {
            log("pre-spawn hook returned invalid JSON: \(error)")
            return .deny(reason: "pre-spawn hook returned invalid JSON")
        }
    }

    private func outcome(for decision: SpawnHookDecision, request: SpawnHookRequest) -> SpawnHookGateOutcome {
        switch decision {
        case .allow:
            return .proceed(echoGrant(for: request))
        case .deny(let reason):
            return .deny(reason: reason)
        case .rewrite(let command, let workingDirectory, let environment):
            let finalCommand: String?
            if let command {
                finalCommand = command
            } else {
                finalCommand = request.command
            }
            var finalEnvironment = request.environmentAdditions
            for (key, value) in environment {
                finalEnvironment[key] = value
            }
            return .proceed(SpawnHookGrant(
                command: finalCommand,
                workingDirectory: workingDirectory ?? request.workingDirectory,
                environmentOverrides: finalEnvironment
            ))
        }
    }

    private func echoGrant(for request: SpawnHookRequest) -> SpawnHookGrant {
        SpawnHookGrant(
            command: request.command,
            workingDirectory: request.workingDirectory,
            environmentOverrides: request.environmentAdditions
        )
    }
}
