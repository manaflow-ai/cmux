/// Pure policy that gates classification actions on managed-session evidence.
public struct AgentStallSupervisorPolicy: Equatable, Sendable {
    /// Maximum retries and backoff used by cmux's managed-session supervisor.
    public static let standard = AgentStallSupervisorPolicy(
        backoffSeconds: [1, 2, 4]
    )

    /// Delay values indexed by the one-based retry attempt.
    public let backoffSeconds: [Int]

    /// Maximum retry commands launched for one managed turn chain.
    public var maximumAttempts: Int { backoffSeconds.count }

    /// Creates a bounded policy.
    ///
    /// Each entry permits one retry. Negative delays are clamped to zero, and
    /// an empty list safely disables retries.
    ///
    /// - Parameter backoffSeconds: One delay for each permitted retry attempt.
    public init(backoffSeconds: [Int]) {
        self.backoffSeconds = backoffSeconds.map { max(0, $0) }
    }

    /// Selects retry, notification, or an explicit fail-closed rejection.
    ///
    /// - Parameter input: Immutable evidence for one managed turn boundary.
    /// - Returns: The only action permitted by the supplied evidence.
    public func decision(
        for input: AgentStallSupervisorInput
    ) -> AgentStallSupervisorDecision {
        guard let classification = input.classification else {
            return .ignore(.unknownClassification)
        }
        guard input.hasManagedLifecycle else {
            return .ignore(.unmanagedSession)
        }
        guard input.session.isComplete else {
            return .ignore(.incompleteSession)
        }
        guard AgentStallClassifier.canonicalProvider(input.session.provider) == classification.provider else {
            return .ignore(.providerMismatch)
        }
        guard input.observedGeneration == input.activeGeneration else {
            return .ignore(.staleGeneration)
        }
        guard input.promptBoundary == .managedPromptIdle else {
            return .ignore(.notIdle)
        }
        switch input.processLiveness {
        case .running:
            break
        case .exited:
            return .ignore(.processExited)
        case .unknown:
            return .ignore(.processUnknown)
        }
        guard input.hasManagedBinding, input.bindingMatches else {
            return .ignore(.invalidBinding)
        }
        guard !input.userInterrupted else {
            return .ignore(.userInterrupted)
        }
        guard !input.normalCompletion else {
            return .ignore(.normalCompletion)
        }

        switch classification.disposition {
        case .humanRequired:
            return .notify(
                cause: classification.cause,
                suggestedActionID: classification.suggestedActionID
            )
        case .retryable:
            guard input.autoRetryEnabled else { return .ignore(.disabled) }
            guard let actionID = classification.retryActionID, !actionID.isEmpty else {
                return .ignore(.missingRetryAction)
            }
            let completed = max(0, input.completedRetryAttempts)
            guard completed < maximumAttempts else { return .ignore(.exhausted) }
            let attempt = completed + 1
            return .retry(
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                delaySeconds: backoffSeconds[attempt - 1],
                actionID: actionID
            )
        }
    }
}
