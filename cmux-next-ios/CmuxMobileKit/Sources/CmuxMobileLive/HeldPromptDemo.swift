#if os(iOS) && DEBUG
import CmuxMobileAgentChat

/// The `offline-held` demo's chat (`-cmux-mobile-demo offline-held`): the app's own source for a
/// chat whose Mac has not answered (`PendingAgentSource`), with a 2 s hold instead of 10 s, so a
/// simulator shot shows the notice a held prompt comes back with. The text is the source's own.
public enum HeldPromptDemo {
    @MainActor
    public static func source(summary: AgentSessionSummary) -> any AgentSessionSource {
        let source = PendingAgentSource(summary: summary, cache: nil, keptKey: nil, onKept: { _ in })
        source.holdWindow = .seconds(2)
        return source
    }
}
#endif
