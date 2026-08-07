/// All reconciliation evidence retained for one panel status key.
nonisolated struct AgentLifecycleEntry: Equatable, Sendable {
    var hook: AgentLifecycleHookObservation?
    var feedAttentionTokens: Set<AgentFeedAttentionToken> = []
    var liveProcessGeneration: AgentProcessGeneration?
    var exitedProcessGeneration: AgentProcessGeneration?
    var hasUnidentifiedProcessExit = false
    var suppressesLifecycleUntilNextHook = false
    var isBuiltIn = false

    var hasProcessExitTombstone: Bool {
        exitedProcessGeneration != nil || hasUnidentifiedProcessExit
    }

    var resolution: AgentLifecycleResolution? {
        if !feedAttentionTokens.isEmpty {
            return AgentLifecycleResolution(
                lifecycle: .needsInput,
                confidence: .feedAttention
            )
        }
        if suppressesLifecycleUntilNextHook {
            return nil
        }
        if let liveProcessGeneration {
            guard let hook else {
                return AgentLifecycleResolution(
                    lifecycle: .unknown,
                    confidence: .liveProcess
                )
            }
            guard hook.processGeneration == liveProcessGeneration else {
                return AgentLifecycleResolution(
                    lifecycle: .unknown,
                    confidence: .liveProcess
                )
            }
            return AgentLifecycleResolution(
                lifecycle: hook.lifecycle,
                confidence: .liveProcess
            )
        }
        if hasProcessExitTombstone, isBuiltIn {
            return nil
        }
        return hook.map {
            AgentLifecycleResolution(
                lifecycle: $0.lifecycle,
                confidence: .unboundHook
            )
        }
    }

    var canBeRemoved: Bool {
        hook == nil
            && feedAttentionTokens.isEmpty
            && liveProcessGeneration == nil
            && exitedProcessGeneration == nil
            && !hasUnidentifiedProcessExit
    }
}
