/// Admission result for a coalesced Ghostty configuration reload request.
struct TerminalConfigurationReloadEnqueueResult {
    let needsFontWorkBarrier: Bool
    let rejectedCompletionCount: Int

    var retainedAllCompletions: Bool {
        rejectedCompletionCount == 0
    }
}
