import Foundation

/// App strings for history (table History.xcstrings).
enum HistoryAppStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "History", bundle: .module)
    }

    static var nothingBack: String { t("history.refusal.nothingBack", "No earlier location to go back to") }
    static var nothingForward: String { t("history.refusal.nothingForward", "No later location to go forward to") }
    static var nothingClosed: String { t("history.refusal.nothingClosed", "No recently closed tab to reopen") }
    static var noSession: String { t("history.refusal.noSession", "No agent session with that ID") }
    static var noResume: String { t("history.refusal.noResume", "cmux does not know how to resume this agent") }
    static var machineOffline: String { t("history.refusal.machineOffline", "That machine is not connected") }
    static var noPane: String { t("history.refusal.noPane", "Open a window on that machine first") }
    static var entryGone: String { t("history.refusal.entryGone", "That history entry is gone") }

    static func undoClosesPanes(_ count: Int) -> String {
        String(format: t("history.refusal.undoClosesPanes", "Undo closes %lld pane(s). Run Undo Layout Change again to confirm."), count)
    }

    static func screenTitle(_ number: Int) -> String {
        String(format: t("history.closed.screenTitle", "Screen %lld"), number)
    }

    static func reopenWorkspaceOnMachine(_ machine: String) -> String {
        String(format: t("history.refusal.reopenWorkspaceOnMachine", "Switch a window to %@ to reopen this workspace there"), machine)
    }

    static var locationsTitle: String { t("history.page.locations", "Location History") }
    static var closedTitle: String { t("history.page.closed", "Recently Closed") }
    static var searchTitle: String { t("history.page.search", "Search History") }
    static var commandsTitle: String { t("history.page.commands", "Command History") }
    static var commandsPlaceholder: String { t("history.page.commandsPlaceholder", "Search commands…") }
    static var agentsTitle: String { t("history.page.agents", "Agent Sessions") }
    static var searchPlaceholder: String { t("history.page.searchPlaceholder", "Search pages, places, agents…") }
    static var locationsPlaceholder: String { t("history.page.locationsPlaceholder", "Search where you were…") }
    static var closedPlaceholder: String { t("history.page.closedPlaceholder", "Search closed tabs…") }
    static var agentsPlaceholder: String { t("history.page.agentsPlaceholder", "Search agent sessions…") }

    static var open: String { t("history.command.open", "Open") }
    static var openInNewTab: String { t("history.command.openInNewTab", "Open in New Tab") }
    static var goTo: String { t("history.command.goTo", "Go To") }
    static var reopen: String { t("history.command.reopen", "Reopen") }
    static var resume: String { t("history.command.resume", "Resume") }
    static var copyURL: String { t("history.command.copyURL", "Copy URL") }
    static var copySessionID: String { t("history.command.copySessionID", "Copy Session ID") }
    static var copyResumeCommand: String { t("history.command.copyResume", "Copy Resume Command") }
    static var remove: String { t("history.command.remove", "Remove from History") }
    static var unknownCommand: String { t("history.command.unknown", "Command") }
    static var runAgain: String { t("history.command.runAgain", "Run Again") }
    static var copyCommand: String { t("history.command.copyCommand", "Copy Command") }
    static var current: String { t("history.accessory.current", "Current") }
    static var offline: String { t("history.accessory.offline", "Offline") }
    static var running: String { t("history.accessory.running", "Running") }

    static func agentTitle(provider: String, cwd: String?) -> String {
        let name = providerName(provider)
        guard let cwd, !cwd.isEmpty else { return name }
        let folder = (cwd as NSString).lastPathComponent
        return String(format: t("history.agent.titleIn", "%1$@ in %2$@"), name, folder)
    }

    /// A provider's product name (not localized).
    static func providerName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude", "claude-code", "claude_code": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "amp": "Amp"
        case "gemini": "Gemini"
        default: provider
        }
    }
}
