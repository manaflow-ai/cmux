// Help rows the menu bar menu and the Help menu share (user 2026-10-27: "make cmux-next menubar,
// be inspired by raycast ... we have discord instead of slack, we have @cmux now"): cmux's community
// links, support, and the logs a bug report needs. Each opens a page or Finder, or copies text, so a
// script or agent gains nothing from a CLI verb (`cmux errors` already reads the logs).

nonisolated enum HelpLinkActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let gui = ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
        return [
            ActionDescriptor(
                id: "help.setupGuide",
                title: String(localized: "action.help.setupGuide", defaultValue: "Setup Guide", bundle: .module),
                keywords: ["setup", "onboarding", "sign in", "accounts", "agent", "help"], category: .settings,
                symbol: "book", surfaces: [.palette, .menu], mainMenu: .help, surfacePlan: gui
            ),
            ActionDescriptor(
                id: "help.troubleshooting",
                title: String(localized: "action.help.troubleshooting", defaultValue: "Troubleshooting and Support", bundle: .module),
                keywords: ["help", "support", "problem", "bug", "contact", "email"], category: .settings,
                symbol: "lifepreserver", surfaces: [.palette, .menu], mainMenu: .help, surfacePlan: gui
            ),
            ActionDescriptor(
                id: "help.discord",
                title: String(localized: "action.help.discord", defaultValue: "Join the cmux Discord", bundle: .module),
                keywords: ["discord", "community", "chat", "server", "support", "slack"], category: .settings,
                symbol: "bubble.left.and.bubble.right", surfaces: [.palette, .menu], mainMenu: .help, surfacePlan: gui
            ),
            ActionDescriptor(
                id: "help.followOnX",
                title: String(localized: "action.help.followOnX", defaultValue: "Follow @cmux on X", bundle: .module),
                keywords: ["x", "twitter", "follow", "news", "updates", "social"], category: .settings,
                symbol: "at", surfaces: [.palette, .menu], mainMenu: .help, surfacePlan: gui
            ),
            ActionDescriptor(
                id: "help.github",
                title: String(localized: "action.help.github", defaultValue: "cmux on GitHub", bundle: .module),
                keywords: ["github", "source", "code", "repository", "issues", "star"], category: .settings,
                symbol: "chevron.left.forwardslash.chevron.right", surfaces: [.palette, .menu], mainMenu: .help, surfacePlan: gui
            ),
            ActionDescriptor(
                id: "help.revealLogs",
                title: String(localized: "action.help.revealLogs", defaultValue: "Reveal Logs in Finder", bundle: .module),
                keywords: ["logs", "errors", "diagnostics", "finder", "folder", "debug"], category: .settings,
                symbol: "folder", surfaces: [.palette, .menu], mainMenu: .help, surfacePlan: gui
            ),
            ActionDescriptor(
                id: "help.copyLogs",
                title: String(localized: "action.help.copyLogs", defaultValue: "Copy Logs", bundle: .module),
                keywords: ["logs", "errors", "diagnostics", "copy", "clipboard", "bug report", "support"], category: .settings,
                symbol: "doc.on.clipboard", surfaces: [.palette, .menu], mainMenu: .help, surfacePlan: gui
            ),
        ]
    }
}
