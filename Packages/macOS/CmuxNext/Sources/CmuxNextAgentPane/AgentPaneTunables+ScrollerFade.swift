public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Whether the agent chat's scrollbars (transcript and composer) fade out at rest. On (the
    /// default since Lawrence 2026-10-23, msg 11494: "auto-fades away, and grows bigger on
    /// near-hover"), the thumb fades in while the user scrolls and out once it stops, over the
    /// pane's fade durations, and shows wide while the pointer is near its edge (webviews
    /// scrollers.ts `SCROLLER_FADE_ATTRIBUTE`, `NEAR_ATTRIBUTE`). The view following new rows is
    /// not a scroll: it never flashes the thumb. Off, the thin thumb stays shown the whole time
    /// the chat overflows (Leo 2026-10-21). The page gets it with the theme (`AgentPaneTheme`,
    /// `scrollerFade`): new agent tabs, and open ones on their next theme push.
    public static let scrollerFade = Tunable<Bool>.toggle(
        "agentPane.debug.scrollerFade", PageTunables.section, "Agent chat scrollbar fades at rest",
        help: "The chat's scrollbars fade in while you scroll and out once you stop, and widen near the pointer. Off, they stay shown while the chat overflows.",
        default: true, code: "AgentPaneTunables.scrollerFade")
}
