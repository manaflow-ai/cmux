import Foundation

extension SettingsSearchIndex {
    static var terminalSettingEntries: [SettingsSearchEntry] {
        [
            setting(.terminal, "scrollbar", String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar"), "terminal shell scrollback"),
            setting(.terminal, "copy-on-select", String(localized: "settings.terminal.copyOnSelect", defaultValue: "Copy on Selection"), "terminal.copyOnSelect clipboard selection mouse double click triple click"),
            setting(.terminal, "inline-image-thumbnails", String(localized: "settings.terminal.inlineImageThumbnails", defaultValue: "Inline Image Thumbnails"), "terminal.inlineImageThumbnails image thumbnail preview quick look quicklook png jpg jpeg gif webp heic screenshot plot"),
            setting(.terminal, "tab-bar-font-size", String(localized: "settings.terminal.tabBarFontSize", defaultValue: "Tab Bar Font Size"), "font size text scale terminal browser pane tab title surface-tab-bar-font-size"),
            setting(.terminal, "agent-auto-resume", String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"), "terminal.autoResumeAgentSessions auto resume restore reopen relaunch quit sessions agents claude code codex opencode rovo dev rovodev toggle"),
            setting(.terminal, "agent-hibernation", String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation"), "terminal.agentHibernation idle hibernate suspend background agents claude code codex opencode live terminals"),
            setting(.terminal, "renderer-realization", String(localized: "settings.terminal.rendererRealization", defaultValue: "Reclaim Offscreen Terminal Memory"), "terminal.rendererRealization renderer reclaim offscreen memory iosurface gpu idle warm release background terminals"),
            setting(.terminal, "resume-commands", String(localized: "settings.terminal.resumeCommands", defaultValue: "Resume Commands"), "surface resume command approvals prefixes auto restore prompt manual tmux hibernation"),
        ]
    }
}
