import CoreGraphics

/// The agent chat's look (Settings > Appearance > Agent Chat; plans/cmux-next/chat-display-settings-DESIGN.md):
/// the same kind of rows the Markdown viewer has, under `agentPane.display`. The chat page reads the
/// same names and ranges (webviews/src/agent-session/acpmux/chatDisplay.ts `CHAT_DISPLAY`), and its
/// ··· menu's Text & Width popover writes them. `inspector.placement` is where the chat's Session Info
/// opens (webviews/src/agent-session/acpmux/session-info/SessionInfo.tsx), and `environment.placement`
/// controls the machine · folder chip below the tab row (webviews/.../header/EnvironmentLine.tsx).
///
/// The font, code font and code size have no value of their own by default: the chat then follows
/// the Markdown viewer's (`markdown.font.preset`, `markdown.code.family`, `markdown.code.scale`),
/// and code follows the terminal font. Sizes and width never follow the viewer.
nonisolated enum AgentPaneDisplaySettingsSchema {
    /// `agentPane.display`, the rows' parent.
    static let section = ["agentPane", "display"]
    /// `agentPane.display.width`: the column's cap in points.
    static let widthRange: ClosedRange<CGFloat> = 480...4000
    static let widthFallback: Double = 800
    static let fontSizeRange: ClosedRange<CGFloat> = 10...28
    static let fontSizeFallback: Double = 14
    static let lineHeightFallback: Double = 1.625
    static let codeScaleFallback: Double = 0.875

    /// Every row's key (agents may set them: looks only).
    static var keys: Set<String> { Set(descriptors.map(\.id)) }

    /// `agentPane.display.sessionInfo.placement`, the Session Info row (Push or Overlay).
    static let sessionInfoPlacementPath = section + ["sessionInfo", "placement"]
    /// The key the Session Info row had before (``RenamedSettingKeys``); a file that still holds it applies.
    static let legacySessionInfoPlacementPath = section + ["inspector", "placement"]

    /// `agentPane.display.minimap`, the Chat Minimap row.
    static let minimapKey = (section + ["minimap"]).joined(separator: ".")

    /// A stored value as the chat page and schema readers read it. `agentPane.display.minimap` was an on/off toggle
    /// before it was the Rail / Full Map / Off choice: on (`true`) was the full map, and off (`false`)
    /// left the chat to the thread minimap experiment, which no value means now. Every other value
    /// is returned as stored; the row still checks it.
    ///
    /// - Parameters:
    ///   - id: The dotted key.
    ///   - value: The value cmux-next.json holds.
    /// - Returns: The value to check against the row, or nil for none.
    static func pageValue(_ id: String, _ value: JSONValue) -> JSONValue? {
        guard id == minimapKey, case .bool(let on) = value else { return value }
        return on ? .string("full") : nil
    }

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.agentChat", "Agent Chat")
        func row(_ path: [String], _ title: SettingText, help: SettingText? = nil, _ kind: SettingKind,
                 _ value: JSONValue?, _ keywords: [String]) -> SettingDescriptor {
            SettingDescriptor(section + path, section: .appearance, group: group, title: title, help: help,
                              kind: kind, default: value, keywords: ["agent", "chat", "acp", "display", "reading"] + keywords)
        }
        return [
            row(["width"], SettingsText.keyed("settings.agentPane.display.width", "Chat Text Width"),
                help: SettingsText.keyed("settings.agentPane.display.width.help",
                                         "The widest the chat's column gets. On a wider pane the chat stays centered."),
                .number(SettingsSchema.points(widthRange, step: 10, placeholder: widthFallback)), .number(widthFallback),
                ["width", "max width", "column", "measure", "wide"]),
            row(["fullWidth"], SettingsText.keyed("settings.agentPane.display.fullWidth", "Chat Full Width"),
                help: SettingsText.keyed("settings.agentPane.display.fullWidth.help", "The chat fills the whole pane instead of the text width."),
                .toggle, .bool(false), ["full", "width", "wide"]),
            // The VS Code-style picture of the whole chat at its right edge (webviews chatMinimap/ChatMinimap.tsx).
            // Off by default; the thread rail at the left (Toggle Thread Minimap) is its own thing.
            row(["vscodeMinimap"], SettingsText.keyed("settings.agentPane.display.vscodeMinimap", "VS Code Minimap"),
                help: SettingsText.keyed("settings.agentPane.display.vscodeMinimap.help",
                                         "A small picture of the whole chat at its right edge, as in VS Code. Click or drag it to scroll."),
                .toggle, .bool(false), ["minimap", "vscode", "vs code", "code", "map", "overview", "scroll", "scrollbar", "right", "toggle"]),
            // The running turn's task list pinned under its latest message (webviews conversation/turns.ts).
            // Off by default: the composer's hat shows it (subagents/SubagentTray.tsx `plan`; Leo, 2026-11-03).
            row(["pinnedPlan"], SettingsText.keyed("settings.agentPane.display.pinnedPlan", "Pin Task List in Chat"),
                help: SettingsText.keyed("settings.agentPane.display.pinnedPlan.help",
                                         "While the agent works, its task list stays under the latest message instead of in the bar over the composer."),
                .toggle, .bool(false), ["plan", "task", "tasks", "todo", "checklist", "pin", "pinned", "list", "progress"]),
            // The hat over the composer tucked away to a pull tab at the composer's top middle (webviews
            // subagents/TrayPullTab.tsx; Leo, 2026-11-04: "what if you wanted to collapse that one line?").
            // The hat's own chevron and the tab write it too.
            row(["trayTucked"], SettingsText.keyed("settings.agentPane.display.trayTucked", "Tuck Away Running Tray"),
                help: SettingsText.keyed("settings.agentPane.display.trayTucked.help",
                                         "Hides the bar of running work over the composer. Hover the top middle of the composer and click its chevron to bring it back."),
                .toggle, .bool(false), ["tray", "hat", "tuck", "hide", "collapse", "running", "background", "subagents", "commands", "bar", "composer", "toggle"]),
            // Where along the composer's top edge the hat's tuck chevron and its pull tab sit (webviews
            // subagents/TrayPullTab.tsx; Leo, 2026-11-04: "I also wonder if we'd want the
            // grabber/dogear/whatever design thing on maybe the left… or the right…").
            row(["trayHandle"], SettingsText.keyed("settings.agentPane.display.trayHandle", "Running Tray Handle"),
                help: SettingsText.keyed("settings.agentPane.display.trayHandle.help",
                                         "Where the handle that tucks the running tray away and brings it back sits along the top of the composer."),
                .choice([
                    SettingChoice("left", SettingsText.keyed("settings.choice.left", "Left")),
                    SettingChoice("middle", SettingsText.keyed("settings.choice.middle", "Middle")),
                    SettingChoice("right", SettingsText.keyed("settings.choice.right", "Right")),
                ]),
                .string("middle"), ["tray", "hat", "tuck", "handle", "grabber", "pull", "tab", "side", "left", "middle", "center", "right", "composer"]),
            row(["font", "preset"], SettingsText.keyed("settings.agentPane.display.font", "Chat Font"),
                .choice([
                    SettingChoice("markdown", SettingsText.keyed("settings.choice.agentChatFontMarkdown", "Same as Markdown Viewer")),
                    SettingChoice("system", SettingsText.keyed("settings.choice.markdownFontSystem", "System")),
                    SettingChoice("serif", SettingsText.keyed("settings.choice.markdownFontSerif", "Serif")),
                    SettingChoice("mono", SettingsText.keyed("settings.choice.markdownFontMono", "Monospaced")),
                ]),
                .string("markdown"), ["font", "family", "serif", "monospace", "typeface"]),
            // The face of the whole chat (webviews .../chatUiFont.ts; Leo, 2026-11-05: "I haven't tried
            // switching fonts in my own app yet. So we could just try some stuff like that"). The
            // default is today's: Inter with its calculated tracking.
            row(["font", "ui"], SettingsText.keyed("settings.agentPane.display.uiFont", "Chat Interface Font"),
                help: SettingsText.keyed("settings.agentPane.display.uiFont.help",
                                         "The font of the whole chat: replies, the composer, cards and menus."),
                .choice([
                    SettingChoice("inter-tuned", SettingsText.keyed("settings.choice.agentChatUiFontInterTuned", "cmux Inter (default)")),
                    SettingChoice("inter", SettingsText.keyed("settings.choice.agentChatUiFontInter", "Inter")),
                    SettingChoice("verdana", SettingsText.keyed("settings.choice.agentChatUiFontVerdana", "Verdana")),
                    SettingChoice("roboto", SettingsText.keyed("settings.choice.agentChatUiFontRoboto", "Roboto")),
                    SettingChoice("plex", SettingsText.keyed("settings.choice.agentChatUiFontPlex", "IBM Plex Sans")),
                    SettingChoice("source-sans", SettingsText.keyed("settings.choice.agentChatUiFontSourceSans", "Source Sans 3")),
                    SettingChoice("geist", SettingsText.keyed("settings.choice.agentChatUiFontGeist", "Geist")),
                    SettingChoice("system-ui", SettingsText.keyed("settings.choice.agentChatUiFontSystemUi", "System")),
                    SettingChoice("system-ui-tight", SettingsText.keyed("settings.choice.agentChatUiFontSystemUiTight", "System, tight")),
                ]),
                .string("inter-tuned"), ["font", "interface", "ui", "typeface", "verdana", "roboto", "inter", "plex", "geist", "source sans"]),
            row(["font", "size"], SettingsText.keyed("settings.agentPane.display.fontSize", "Chat Font Size"),
                .number(SettingsSchema.points(fontSizeRange, step: 1, placeholder: fontSizeFallback)), .number(fontSizeFallback),
                ["font", "size", "text"]),
            row(["font", "lineHeight"], SettingsText.keyed("settings.agentPane.display.lineHeight", "Chat Line Height"),
                .number(SettingNumber(1.2...2.4, step: 0.05, unit: .fraction, placeholder: lineHeightFallback)), .number(lineHeightFallback),
                ["line height", "leading", "line spacing"]),
            row(["code", "family"], SettingsText.keyed("settings.agentPane.display.codeFont", "Chat Code Font"),
                help: SettingsText.keyed("settings.agentPane.display.codeFont.help",
                                         "The font of code in the chat. Empty uses the Markdown viewer's code font, then the terminal font."),
                .fontFamily, nil, ["code", "font", "monospace", "family"]),
            row(["code", "scale"], SettingsText.keyed("settings.agentPane.display.codeSize", "Chat Code Size"),
                help: SettingsText.keyed("settings.agentPane.display.codeSize.help",
                                         "Code as a share of the chat's text size. Empty uses the Markdown viewer's."),
                .number(SettingNumber(0.6...1.25, step: 0.025, unit: .fraction, placeholder: codeScaleFallback)), nil,
                ["code", "font", "size", "monospace", "scale"]),
            row(["sessionInfo", "placement"], SettingsText.keyed("settings.agentPane.display.inspector", "Session Info"),
                help: SettingsText.keyed("settings.agentPane.display.inspector.help",
                                         "Where the Session Info panel opens at the right of the chat. Push narrows the chat beside it; Overlay lies over the chat."),
                .choice([
                    SettingChoice("push", SettingsText.keyed("settings.choice.agentChatInspectorPush", "Push")),
                    SettingChoice("overlay", SettingsText.keyed("settings.choice.agentChatInspectorOverlay", "Overlay")),
                ]),
                .string("overlay"), ["session", "info", "inspector", "panel", "side", "right", "overlay", "push", "details"]),
            row(["environment", "placement"], SettingsText.keyed("settings.agentPane.display.environment", "Session Info Chip"),
                help: SettingsText.keyed("settings.agentPane.display.environment.help",
                                         "Left puts it in a row below the tab row; Right keeps it in the header (or leads the tab-row tools); Off hides it."),
                .choice([
                    SettingChoice("left", SettingsText.keyed("settings.choice.left", "Left")),
                    SettingChoice("right", SettingsText.keyed("settings.choice.right", "Right")),
                    SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off")),
                ]),
                .string("left"), ["session", "info", "chip", "environment", "machine", "folder", "placement", "left", "right", "off"]),
            // What the chat's edge shows (webviews threadMinimap/ThreadMinimap.tsx): the prompt rail
            // of ticks, the full map (ScrollMap.tsx),
            // or nothing. The values are the `thread-minimap-layout` experiment's arms and the
            // default is its default arm (webviews/test/thread-minimap-setting.test.ts checks both),
            // so the row never says one thing while the chat shows another. The keywords are the
            // words people search for it with (Leo, 2026-10-22, searching "TICK RAIL": "doesn't
            // show as an option").
            row(["minimap"], SettingsText.keyed("settings.agentPane.display.minimap", "Chat Minimap"),
                help: SettingsText.keyed("settings.agentPane.display.minimap.help",
                                         "What runs down the chat's edge: the rail, one tick per prompt; the full map, every message at its place with a box for what is on screen; or nothing."),
                .choice([
                    SettingChoice("compact", SettingsText.keyed("settings.choice.agentChatMinimapRail", "Rail")),
                    SettingChoice("full", SettingsText.keyed("settings.choice.agentChatMinimapFull", "Full Map")),
                    SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off")),
                ]),
                .string("compact"), ["minimap", "thread minimap", "map", "overview", "scroll", "vscode", "rail", "tick", "ticks",
                                 "wave", "prompt rail", "scroll rail", "prompts"]),
            // How much of each turn a chat shows (webviews conversation/transcriptView.ts), Claude Code
            // desktop's Transcript view: a chat's ··· menu changes its own, and its "Make … the default"
            // writes this row.
            row(["transcriptView"], SettingsText.keyed("settings.agentPane.display.transcriptView", "Transcript View"),
                help: SettingsText.keyed("settings.agentPane.display.transcriptView.help",
                                         "How much of each turn a chat shows. Normal folds thinking and tool output; Thinking opens thinking; Verbose also opens tool output. A chat's ··· menu changes its own view."),
                .choice([
                    SettingChoice("normal", SettingsText.keyed("settings.choice.transcriptViewNormal", "Normal")),
                    SettingChoice("thinking", SettingsText.keyed("settings.choice.transcriptViewThinking", "Thinking")),
                    SettingChoice("verbose", SettingsText.keyed("settings.choice.transcriptViewVerbose", "Verbose")),
                ]),
                .string("normal"), ["transcript", "view", "verbose", "thinking", "thoughts", "reasoning", "tool output",
                                    "expand", "collapse", "fold", "details"]),
            row(["presentation"], SettingsText.keyed("settings.agentPane.display.presentation", "Chat Presentation"),
                .choice([
                    SettingChoice("transcript", SettingsText.keyed("settings.choice.agentChatPresentationTranscript", "Transcript")),
                    SettingChoice("messages", SettingsText.keyed("settings.choice.agentChatPresentationMessages", "Messages")),
                ]),
                .string("transcript"), ["presentation", "messages", "bubbles", "chat", "tools"]),
            // The live line's short working verbs (webviews/.../statusVerbs.ts). Thinking is the
            // default; Rotate opts into the per-turn -ing verbs and Custom reads the comma list.
            row(["statusVerbs", "mode"], SettingsText.keyed("settings.agentPane.display.statusVerbs", "Working Status Verbs"),
                help: SettingsText.keyed("settings.agentPane.display.statusVerbs.help",
                                         "Choose whether the live status line rotates through verbs or stays on Thinking."),
                .choice([
                    SettingChoice("thinking", SettingsText.keyed("settings.choice.agentChatStatusVerbsThinking", "Thinking only")),
                    SettingChoice("rotate", SettingsText.keyed("settings.choice.agentChatStatusVerbsRotate", "Rotate")),
                    SettingChoice("custom", SettingsText.keyed("settings.choice.agentChatStatusVerbsCustom", "Custom")),
                ]),
                .string("thinking"), ["status", "working", "verbs", "thinking", "spinner", "rotate", "custom"]),
            row(["statusVerbs", "custom"], SettingsText.keyed("settings.agentPane.display.statusVerbs.custom", "Custom Working Verbs"),
                help: SettingsText.keyed("settings.agentPane.display.statusVerbs.custom.help",
                                         "Comma-separated -ing verbs for the live status line."),
                .text, nil, ["status", "working", "verbs", "custom", "comma", "thinking"]),
            row(["harnessPlacement"], SettingsText.keyed("settings.agentPane.display.harnessPlacement", "Model Picker Harness Placement"),
                .choice([
                    SettingChoice("symbols", SettingsText.keyed("settings.choice.harnessSymbols", "Top Row of Symbols")),
                    SettingChoice("left", SettingsText.keyed("settings.choice.harnessLeft", "Left Rail with Names")),
                    SettingChoice("top", SettingsText.keyed("settings.choice.harnessTop", "Top Strip with Names")),
                    SettingChoice("compact", SettingsText.keyed("settings.choice.harnessCompact", "Compact Left Rail")),
                ]),
                .string("symbols"), ["model", "picker", "harness", "placement", "left", "top", "symbols"]),
            row(["rail", "side"], SettingsText.keyed("settings.agentPane.display.rail.side", "Prompt Rail Side"),
                help: SettingsText.keyed("settings.agentPane.display.rail.side.help",
                                         "The edge of the chat the prompt rail sits on, one tick per prompt. Right-click the rail to move it."),
                .choice([
                    SettingChoice("left", SettingsText.keyed("settings.choice.left", "Left")),
                    SettingChoice("right", SettingsText.keyed("settings.choice.right", "Right")),
                ]),
                .string("left"), ["rail", "minimap", "prompts", "ticks", "scroll", "side", "left", "right"]),
            // How the chat's running tray names background commands no built-in rule knows
            // (``CommandLabelsSetting``; webviews session-info/commandLabelSettings.ts): preset names
            // and rules of one's own, edited as JSON.
            row(["commandLabels"], SettingsText.keyed("settings.agentPane.display.commandLabels", "Command Labels"),
                help: SettingsText.keyed("settings.agentPane.display.commandLabels.help",
                                         "How the chat names background commands: preset names such as cmux-fleet, and rules with a program or pattern and a label."),
                .text, .array([]), ["command", "label", "rule", "preset", "background", "tray", "shell"])
                .hiddenFromSettingsPage("a list of preset names and rule objects, edited in cmux-next.json"),
        ]
    }
}
