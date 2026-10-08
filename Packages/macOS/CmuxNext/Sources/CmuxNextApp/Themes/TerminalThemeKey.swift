import CmuxNextDaemon

/// Names one terminal for its own theme: the machine whose session runs it
/// and its id there (its terminal id, else its tab id). The home session
/// stores the theme under `{session_id, terminal}` (`personal-terminals-v1`);
/// `legacy` is the key of the app-local file used before that
/// (`TerminalThemeStore`).
struct TerminalThemeKey: Hashable {
    let machine: String
    let tab: String
    let terminal: String

    init(machine: String, tab: TabModel) {
        self.machine = machine
        self.tab = tab.id
        terminal = tab.terminalResourceID?.rawValue ?? tab.id
    }

    var legacy: String { TerminalThemeStore.key(machine: machine, tab: tab) }
}
