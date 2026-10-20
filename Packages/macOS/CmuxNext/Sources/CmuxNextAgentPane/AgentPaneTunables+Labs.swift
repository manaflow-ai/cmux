public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    public static let liveRender = Tunable<Bool>.toggle(
        "agentPane.labs.liveRender", PageTunables.section, "Live render cards in chat",
        help: "Render cards draw inline as they are written and can talk back to the chat. New agent tabs.",
        default: true, code: "AgentPaneTunables.liveRender")
    /// Teach the agent once per session while live render is on (Lucas 2026-10-19).
    public static let renderGuide = Tunable<Bool>.toggle(
        "agentPane.labs.renderGuide", PageTunables.section, "Teach agents to draw in chat",
        help: "Send inline render guidance with the first prompt of each agent session while live render is on. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderGuide")
    /// Native defaults stay scoped to live render frames (Lucas 2026-10-19).
    public static let renderKit = Tunable<Bool>.toggle(
        "agentPane.labs.renderKit", PageTunables.section, "Native styles for chat renders",
        help: "Native controls, charts and follow-ups in live chat renders. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderKit")
    /// Agent preview and wide-table trials share the pane's live layout overrides.
    public static let renderPreview = Tunable<Bool>.toggle(
        "agentPane.labs.renderPreview", PageTunables.section, "Let agents preview chat renders",
        help: "Capture sandboxed renders with diagnostics before showing them. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderPreview")
    public static let renderExpand = Tunable<Bool>.toggle(
        "agentPane.labs.renderExpand", PageTunables.section, "Open chat renders larger",
        help: "A quiet hover control opens a render in a larger dialog. New agent tabs.",
        default: true, code: "AgentPaneTunables.renderExpand")
    public static let tableScroll = Tunable<Bool>.toggle(
        "agentPane.labs.tableScroll", PageTunables.section, "Scroll wide chat tables",
        help: "Keep wide tables within the reply column. New agent tabs.",
        default: true, code: "AgentPaneTunables.tableScroll")
    public static let contextMeter = Tunable<Bool>.toggle(
        "agentPane.labs.contextMeter", PageTunables.section, "Context ring beside the model",
        help: "A ring beside the model shows context use and opens its token details. New agent tabs.",
        default: false, code: "AgentPaneTunables.contextMeter")
    public static let promptCollapse = Tunable<Bool>.toggle(
        "agentPane.labs.promptCollapse", PageTunables.section, "Fold long prompts",
        help: "Long prompts fold to eight lines and open for Find. New agent tabs.",
        default: false, code: "AgentPaneTunables.promptCollapse")
    public static let messageTimes = Tunable<Bool>.toggle(
        "agentPane.labs.messageTimes", PageTunables.section, "Prompt send times on hover",
        help: "Prompts show their send time on hover or focus. New agent tabs.",
        default: false, code: "AgentPaneTunables.messageTimes")
    public static let codeWrap = Tunable<Bool>.toggle(
        "agentPane.labs.codeWrap", PageTunables.section, "One wrap choice for all code blocks",
        help: "One remembered wrap choice applies to every code block in the pane. New agent tabs.",
        default: false, code: "AgentPaneTunables.codeWrap")
    public static let planProgress = Tunable<Bool>.toggle(
        "agentPane.labs.planProgress", PageTunables.section, "Plan progress above the composer",
        help: "The running plan's current step stays above the composer. New agent tabs.",
        default: false, code: "AgentPaneTunables.planProgress")
    /// Files and linked files open in one viewer beside the transcript, inside the chat, instead of a
    /// new column or a tab over the chat; Changes opens as without the switch (Lucas 2026-10-19).
    public static let chatViewer = Tunable<Bool>.toggle(
        "agentPane.labs.chatViewer", PageTunables.section, "Files beside the chat",
        help: "Files and files the chat links to open in one viewer beside the transcript, inside the chat, instead of a new column or a tab over the chat. Changes opens as before. New agent tabs.",
        default: true, code: "AgentPaneTunables.chatViewer")
    public static let shortcutsHelp = Tunable<Bool>.toggle(
        "agentPane.labs.shortcutsHelp", PageTunables.section, "Keyboard shortcuts in the chat menu",
        help: "The chat menu shows the keyboard shortcuts available in the pane. New agent tabs.",
        default: false, code: "AgentPaneTunables.shortcutsHelp")
    /// Thread details sources show each site's icon, fetched by the favicon loader (Lucas 2026-10-19).
    public static let sourceIcons = Tunable<Bool>.toggle(
        "agentPane.labs.sourceIcons", PageTunables.section, "Site icons for sources",
        help: "Thread details shows each source's site icon, fetched from the site without cookies. New agent tabs.",
        default: true, code: "AgentPaneTunables.sourceIcons")

    static let labTunables: [String: Tunable<Bool>] = [
        "live-render": liveRender, "render-guide": renderGuide, "render-kit": renderKit, "render-preview": renderPreview, "render-expand": renderExpand, "table-scroll": tableScroll, "context-meter": contextMeter, "prompt-collapse": promptCollapse,
        "message-times": messageTimes, "code-wrap": codeWrap, "plan-progress": planProgress,
        "shortcuts-help": shortcutsHelp, "source-icons": sourceIcons, "chat-viewer": chatViewer
    ]
}
