import CoreGraphics

/// The agent chat's look (Settings > Appearance > Agent Chat; plans/cmux-next/chat-display-settings-DESIGN.md):
/// the same kind of rows the Markdown viewer has, under `agentPane.display`. The chat page reads the
/// same names and ranges (webviews/src/agent-session/acpmux/chatDisplay.ts `CHAT_DISPLAY`), and its
/// ··· menu's Text & Width popover writes them. `inspector.placement` is where the chat's Inspector
/// opens (webviews/src/agent-session/acpmux/inspector/ChatInspector.tsx), and `environment.placement`
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
            row(["font", "preset"], SettingsText.keyed("settings.agentPane.display.font", "Chat Font"),
                .choice([
                    SettingChoice("markdown", SettingsText.keyed("settings.choice.agentChatFontMarkdown", "Same as Markdown Viewer")),
                    SettingChoice("system", SettingsText.keyed("settings.choice.markdownFontSystem", "System")),
                    SettingChoice("serif", SettingsText.keyed("settings.choice.markdownFontSerif", "Serif")),
                    SettingChoice("mono", SettingsText.keyed("settings.choice.markdownFontMono", "Monospaced")),
                ]),
                .string("markdown"), ["font", "family", "serif", "monospace", "typeface"]),
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
            row(["inspector", "placement"], SettingsText.keyed("settings.agentPane.display.inspector", "Session Info"),
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
        ]
    }
}
