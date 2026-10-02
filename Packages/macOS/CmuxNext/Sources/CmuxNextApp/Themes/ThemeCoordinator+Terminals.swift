import CmuxNextDaemon

/// Terminal themes live in the home session's personal state
/// (`personal-terminals-v1`), keyed by the terminal's session and its id
/// there. A home daemon without it keeps them in the app-local file
/// (`TerminalThemeStore`); once it has it, the file's themes move there
/// (each as soon as its machine is connected and its terminal found) and the
/// file empties.
extension ThemeCoordinator {
    private var home: DaemonService { services.machines.local }

    /// The home daemon stores terminal themes, and `key`'s session is known.
    private func personalTarget(_ key: TerminalThemeKey) -> (session: String, terminal: String)? {
        guard home.supports(DaemonCapabilities.shared.personalTerminals),
              let session = services.machines.daemon(machine: key.machine)?.store.registryID else { return nil }
        return (session, key.terminal)
    }

    func savedTerminalTheme(_ key: TerminalThemeKey) -> String? {
        guard let target = personalTarget(key) else { return terminalThemes.theme(for: key.legacy) }
        return home.store.personal.terminalTheme(session: target.session, terminal: target.terminal)
    }

    /// Saves one terminal's own theme (nil clears). Personal state is async:
    /// the value stays pending until the daemon echoes it.
    func saveTerminalTheme(_ spec: String?, for key: TerminalThemeKey) {
        guard let target = personalTarget(key) else {
            terminalThemes.set(spec, for: key.legacy)
            return
        }
        pending[.terminal(key)] = .some(spec)
        home.send("set-personal-terminal") {
            try await $0.setPersonalTerminal(SetPersonalTerminalRequest(sessionID: target.session, terminalKey: target.terminal, theme: spec))
        }
    }

    /// Moves themes from the app-local file into personal state, once the
    /// home daemon stores them. An entry waits while its machine is not
    /// connected; one whose terminal is gone is dropped.
    func migrateTerminalThemes() {
        guard home.supports(DaemonCapabilities.shared.personalTerminals), !terminalThemes.migratableThemes.isEmpty else { return }
        for (legacy, theme) in terminalThemes.migratableThemes {
            guard let split = legacy.lastIndex(of: ":") else { continue }
            let machine = String(legacy[..<split]), tabID = String(legacy[legacy.index(after: split)...])
            guard let daemon = services.machines.daemon(machine: machine), daemon.store.isLoaded,
                  let session = daemon.store.registryID else { continue }
            let tab = daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.id == tabID }
            terminalThemes.set(nil, for: legacy)
            guard let tab else { continue }
            let terminal = TerminalThemeKey(machine: machine, tab: tab).terminal
            home.send("set-personal-terminal") {
                try await $0.setPersonalTerminal(SetPersonalTerminalRequest(sessionID: session, terminalKey: terminal, theme: theme))
            }
        }
    }

    /// Once per launch, after the home daemon's first tree: drops themes of
    /// its own terminals that closed while the app was away (other sessions
    /// are left alone; their terminals may be offline).
    func pruneTerminalThemes() {
        let tabs = home.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        terminalThemes.prune(machine: home.machineID, liveTabs: Set(tabs.map(\.id)))
        guard home.supports(DaemonCapabilities.shared.personalTerminals), let session = home.store.registryID else { return }
        let live = Set(tabs.map { TerminalThemeKey(machine: home.machineID, tab: $0).terminal })
        for terminal in (home.store.personal.terminalThemes[session] ?? [:]).keys where !live.contains(terminal) {
            home.send("set-personal-terminal") {
                try await $0.setPersonalTerminal(SetPersonalTerminalRequest(sessionID: session, terminalKey: terminal, theme: nil))
            }
        }
    }
}
