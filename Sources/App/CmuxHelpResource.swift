import Foundation

enum CmuxHelpResource {
    case gettingStarted
    case concepts
    case configuration
    case customCommands
    case dock
    case keyboardShortcuts
    case apiReference
    case browserAutomation
    case notifications
    case ssh
    case skills
    case claudeCodeTeams
    case ohMyOpenCode
    case ohMyCodex
    case ohMyClaudeCode
    case changelog
    case githubIssues
    case discord

    var title: String {
        switch self {
        case .gettingStarted:
            return String(localized: "menu.help.gettingStarted", defaultValue: "Getting Started")
        case .concepts:
            return String(localized: "menu.help.concepts", defaultValue: "Concepts")
        case .configuration:
            return String(localized: "menu.help.configuration", defaultValue: "Configuration")
        case .customCommands:
            return String(localized: "menu.help.customCommands", defaultValue: "Custom Commands")
        case .dock:
            return String(localized: "menu.help.dock", defaultValue: "Dock")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .apiReference:
            return String(localized: "menu.help.apiReference", defaultValue: "API Reference")
        case .browserAutomation:
            return String(localized: "menu.help.browserAutomation", defaultValue: "Browser Automation")
        case .notifications:
            return String(localized: "menu.help.notifications", defaultValue: "Notifications")
        case .ssh:
            return String(localized: "menu.help.ssh", defaultValue: "SSH")
        case .skills:
            return String(localized: "menu.help.skills", defaultValue: "Skills")
        case .claudeCodeTeams:
            return String(localized: "menu.help.claudeCodeTeams", defaultValue: "Claude Code Teams")
        case .ohMyOpenCode:
            return String(localized: "menu.help.ohMyOpenCode", defaultValue: "oh-my-opencode")
        case .ohMyCodex:
            return String(localized: "menu.help.ohMyCodex", defaultValue: "oh-my-codex")
        case .ohMyClaudeCode:
            return String(localized: "menu.help.ohMyClaudeCode", defaultValue: "oh-my-claudecode")
        case .changelog:
            return String(localized: "menu.help.changelog", defaultValue: "Changelog")
        case .githubIssues:
            return String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues")
        case .discord:
            return String(localized: "sidebar.help.discord", defaultValue: "Discord")
        }
    }

    var url: URL {
        switch self {
        case .gettingStarted:
            return URL(string: "https://cmux.com/docs/getting-started")!
        case .concepts:
            return URL(string: "https://cmux.com/docs/concepts")!
        case .configuration:
            return URL(string: "https://cmux.com/docs/configuration")!
        case .customCommands:
            return URL(string: "https://cmux.com/docs/custom-commands")!
        case .dock:
            return URL(string: "https://cmux.com/docs/dock")!
        case .keyboardShortcuts:
            return URL(string: "https://cmux.com/docs/keyboard-shortcuts")!
        case .apiReference:
            return URL(string: "https://cmux.com/docs/api")!
        case .browserAutomation:
            return URL(string: "https://cmux.com/docs/browser-automation")!
        case .notifications:
            return URL(string: "https://cmux.com/docs/notifications")!
        case .ssh:
            return URL(string: "https://cmux.com/docs/ssh")!
        case .skills:
            return URL(string: "https://cmux.com/docs/skills")!
        case .claudeCodeTeams:
            return URL(string: "https://cmux.com/docs/agent-integrations/claude-code-teams")!
        case .ohMyOpenCode:
            return URL(string: "https://cmux.com/docs/agent-integrations/oh-my-opencode")!
        case .ohMyCodex:
            return URL(string: "https://cmux.com/docs/agent-integrations/oh-my-codex")!
        case .ohMyClaudeCode:
            return URL(string: "https://cmux.com/docs/agent-integrations/oh-my-claudecode")!
        case .changelog:
            return URL(string: "https://cmux.com/docs/changelog")!
        case .githubIssues:
            return URL(string: "https://github.com/manaflow-ai/cmux/issues")!
        case .discord:
            return URL(string: "https://discord.gg/xsgFEVrWCZ")!
        }
    }
}
