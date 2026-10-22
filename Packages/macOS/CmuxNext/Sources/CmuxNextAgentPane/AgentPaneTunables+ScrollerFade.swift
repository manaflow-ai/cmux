public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Whether the agent chat transcript's scrollbar fades out at rest. Off (the default), its thin
    /// thumb stays shown the whole time the chat overflows, as in every agent app, and never flashes
    /// as rows arrive or the view follows them (Leo 2026-10-21: "SCROLLBAR IT SHOULD FUCKING SHOW").
    /// On, it fades in while the transcript scrolls and out once it stops, over the pane's fade
    /// durations (webviews scrollers.ts `SCROLLER_FADE_ATTRIBUTE`). The page gets it with the theme
    /// (`AgentPaneTheme`, `scrollerFade`): new agent tabs, and open ones on their next theme push.
    public static let scrollerFade = Tunable<Bool>.toggle(
        "agentPane.debug.scrollerFade", PageTunables.section, "Agent chat scrollbar fades at rest",
        help: "The transcript's scrollbar fades in while it scrolls and out once it stops. Off, it stays shown while the chat overflows.",
        default: false, code: "AgentPaneTunables.scrollerFade")
}
