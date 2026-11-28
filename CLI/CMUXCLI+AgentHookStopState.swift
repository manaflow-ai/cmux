import Foundation
import CmuxAgentJournal

extension CMUXCLI {
    /// Preserves a same-turn needs-input phase when a completion Stop follows
    /// a question or approval notification.
    static func stopPreservesNeedsInput(
        mapped: ClaudeHookSessionRecord?,
        inputTurnID: String?,
        terminationReason: String? = nil
    ) -> Bool {
        AgentNeedsInputStopContext(
            runtimePhase: mapped?.runtimeStatus.flatMap { AgentLifecyclePhase(rawValue: $0.rawValue) },
            activePromptDepth: mapped?.activePromptDepth ?? 0,
            activePromptTurnIDs: mapped?.activePromptTurnIds ?? [],
            activePromptTurnID: mapped?.activePromptTurnId,
            lastPromptTurnID: mapped?.lastPromptTurnId,
            inputTurnID: inputTurnID,
            terminationReason: terminationReason
        ).shouldPreserveNeedsInput
    }
}
