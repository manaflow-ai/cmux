import Foundation

extension CMUXCLI {
    /// Preserves a same-turn needs-input phase when a completion Stop follows
    /// a question or approval notification.
    static func stopPreservesNeedsInput(
        mapped: ClaudeHookSessionRecord?,
        inputTurnID: String?
    ) -> Bool {
        guard mapped?.runtimeStatus == .needsInput else { return false }
        let normalizedInput = inputTurnID?.trimmingCharacters(in: .whitespacesAndNewlines)
            .flatMap { $0.isEmpty ? nil : $0 }
        if let normalizedInput {
            let activeTurnIDs = mapped?.activePromptTurnIds?.compactMap { value in
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : normalized
            } ?? mapped?.activePromptTurnId.map { [$0] } ?? []
            let lastTurnID = mapped?.lastPromptTurnId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return activeTurnIDs.contains(normalizedInput) || lastTurnID == normalizedInput
        }
        return (mapped?.activePromptDepth ?? 0) > 0
            || mapped?.activePromptTurnId != nil
            || mapped?.activePromptTurnIds?.isEmpty == false
    }
}
