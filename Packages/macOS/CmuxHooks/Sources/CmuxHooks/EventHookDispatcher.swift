public import Foundation

/// Dispatches configured event hooks from cmux event-bus envelopes.
public actor EventHookDispatcher {
    private let configState: @Sendable () -> CmuxHooksConfigState
    private let runner: any HookProcessRunning
    private let log: @Sendable (String) -> Void
    private var tails: [String: Task<Void, Never>] = [:]

    /// Creates an event-hook dispatcher.
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

    /// Returns exact event names with at least one enabled hook.
    /// - Returns: Event names this dispatcher currently subscribes to.
    public func subscribedEventNames() -> Set<String> {
        guard case .loaded(let config) = configState() else { return [] }
        return Set(config.events.compactMap { eventName, hooks in
            hooks.contains { $0.enabled } ? eventName : nil
        })
    }

    /// Dispatches one event envelope to configured hooks.
    /// - Parameters:
    ///   - eventName: Exact event-bus event name.
    ///   - envelopeJSON: Sanitized event envelope JSON.
    public func dispatch(eventName: String, envelopeJSON: Data) {
        guard !eventName.hasPrefix("hook.") else { return }
        guard case .loaded(let config) = configState() else { return }
        let hooks = (config.events[eventName] ?? []).filter(\.enabled)
        guard !hooks.isEmpty else { return }
        let previous = tails[eventName]
        let runner = runner
        let logger = log
        let task = Task {
            await previous?.value
            let expander = HookArgumentExpander(envelopeJSON: envelopeJSON)
            for hook in hooks {
                let result = await runner.run(
                    command: hook.command,
                    arguments: expander.expand(hook.args),
                    stdin: envelopeJSON,
                    timeout: .milliseconds(hook.timeoutMs)
                )
                if let launchFailure = result.launchFailure {
                    logger("event hook \(eventName) launch failed: \(launchFailure)")
                } else if result.timedOut {
                    logger("event hook \(eventName) timed out")
                } else if result.exitStatus != 0 {
                    let status = result.exitStatus.map(String.init) ?? "unknown"
                    logger("event hook \(eventName) exited non-zero: \(status)")
                }
            }
        }
        tails[eventName] = task
    }
}
