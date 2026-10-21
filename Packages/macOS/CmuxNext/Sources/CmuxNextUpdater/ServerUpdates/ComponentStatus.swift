public import CmuxNextDesign
import Foundation

/// What Update cmux Components… found (plans/cmux-next/server-updates-DESIGN.md section 7): the
/// app's own update, this Mac's cmux-tui and acpmux daemons against the builds the app bundles,
/// and the agent CLIs with a newer release. One line per part, and what Update All would run.
public nonisolated struct ComponentStatus: Sendable, Equatable {
    /// The app's own update, from the updater's phase.
    public enum App: Sendable, Equatable {
        /// No update found (or none checked yet).
        case current
        /// A newer version was found; Update All downloads and installs it.
        case available(String?)
        /// A newer version is downloaded; Update All installs it.
        case ready(String?)
    }

    /// A daemon's build against the bundled one; nil `running` means no daemon of this app runs.
    public struct Server: Sendable, Equatable {
        public var running: String?
        public var bundled: String?
        /// A restart keeps its work (terminals for cmux-tui; agents under agent hosts for acpmux).
        public var keepsWork: Bool

        public init(running: String?, bundled: String?, keepsWork: Bool) {
            self.running = running
            self.bundled = bundled
            self.keepsWork = keepsWork
        }

        /// Another build than the bundled one. Builds are compared by their leading commit: one
        /// side may print a short commit (`acpmux --version`) and the other the full one.
        public var isBehind: Bool {
            guard let running = Self.commit(running), let bundled = Self.commit(bundled) else { return false }
            return !(running.hasPrefix(bundled) || bundled.hasPrefix(running))
        }

        /// The leading hex run of a build string (`828d36727 2026-10-21` -> `828d36727`), at least 7.
        static func commit(_ build: String?) -> String? {
            guard let build else { return nil }
            let hex = build.prefix { $0.isHexDigit }.lowercased()
            return hex.count >= 7 ? hex : nil
        }

        /// The build as people read it: its first 9 hex digits.
        static func short(_ build: String?) -> String {
            commit(build).map { String($0.prefix(9)) } ?? UpdaterStrings.text("components.build.unknown", "unknown build")
        }
    }

    public var app: App
    public var appVersion: String
    public var cmuxTUI: Server?
    public var acpmux: Server?
    /// Agent CLIs with a newer release; nil when acpmux could not say.
    public var outdatedAgentCLIs: [String]?

    public init(app: App, appVersion: String, cmuxTUI: Server?, acpmux: Server?, outdatedAgentCLIs: [String]?) {
        self.app = app
        self.appVersion = appVersion
        self.cmuxTUI = cmuxTUI
        self.acpmux = acpmux
        self.outdatedAgentCLIs = outdatedAgentCLIs
    }

    /// Update All installs a newer cmux (the updater's install, which waits for busy agents).
    /// The new app hands both daemons off to its own builds as it starts, so nothing else restarts.
    public var installsApp: Bool { if case .current = app { false } else { true } }
    /// Update All restarts cmux-tui: it runs another build, and a restart keeps every terminal.
    public var restartsCmuxTUI: Bool { !installsApp && cmuxTUI?.isBehind == true }
    /// Update All hands acpmux off: it runs another build and keeps its agents across it.
    /// One without agent hosts keeps running until its agents end; nothing restarts it here.
    public var restartsAcpmux: Bool { !installsApp && (acpmux.map { $0.isBehind && $0.keepsWork } ?? false) }
    /// Update All updates the agent CLIs that have a newer release.
    public var updatesAgentCLIs: Bool { !(outdatedAgentCLIs ?? []).isEmpty }

    /// Whether Update All has anything to run.
    public var hasUpdates: Bool { installsApp || restartsCmuxTUI || restartsAcpmux || updatesAgentCLIs }

    /// One line per part, in the order Update All runs them.
    public var lines: [String] {
        [appLine, cmuxTUI.map(cmuxTUILine), acpmux.map(acpmuxLine), agentCLIsLine].compactMap { $0 }
    }

    /// The dialog: the lines, then Cancel and Update All, or only Done when everything is current.
    public var dialogSpec: CmuxDialogSpec {
        let buttons: [CmuxDialogButton] = hasUpdates
            ? [.cancel(), CmuxDialogButton(id: "update", title: UpdaterStrings.text("components.button.updateAll", "Update All"), role: .default)]
            : [.ok(UpdaterStrings.text("components.button.done", "Done"))]
        let title = hasUpdates
            ? UpdaterStrings.text("components.title.updates", "Updates for cmux Components")
            : UpdaterStrings.text("components.title.current", "cmux Components Are Up to Date")
        return CmuxDialogSpec(title: title, lines: lines, buttons: buttons, identifier: "cmux.components.update")
    }

    private var appLine: String {
        switch app {
        case .current:
            UpdaterStrings.format("components.app.current", "cmux %@: no newer version found.", appVersion)
        case .available(let version):
            UpdaterStrings.format("components.app.available",
                                  "cmux %1$@: version %2$@ is available. Update All installs it and restarts cmux when no agent is busy.",
                                  appVersion, version ?? "?")
        case .ready(let version):
            UpdaterStrings.format("components.app.ready",
                                  "cmux %1$@: version %2$@ is downloaded. Update All installs it and restarts cmux when no agent is busy.",
                                  appVersion, version ?? "?")
        }
    }

    private func cmuxTUILine(_ server: Server) -> String {
        guard server.running != nil else {
            return UpdaterStrings.text("components.cmuxTUI.notRunning", "cmux-tui: not running. It starts on the bundled build.")
        }
        guard server.isBehind else {
            return UpdaterStrings.format("components.cmuxTUI.current", "cmux-tui: up to date (%@).", Server.short(server.running))
        }
        return UpdaterStrings.format("components.cmuxTUI.behind",
                                     "cmux-tui: runs %1$@, this app has %2$@. Update All restarts it; every terminal keeps running.",
                                     Server.short(server.running), Server.short(server.bundled))
    }

    private func acpmuxLine(_ server: Server) -> String {
        guard server.running != nil else {
            return UpdaterStrings.text("components.acpmux.notRunning", "acpmux: not running. It starts on the bundled build.")
        }
        guard server.isBehind else {
            return UpdaterStrings.format("components.acpmux.current", "acpmux: up to date (%@).", Server.short(server.running))
        }
        guard server.keepsWork else {
            return UpdaterStrings.format("components.acpmux.keeps",
                                         "acpmux: runs %1$@, this app has %2$@. Restarting it would end its agents, so it keeps running and updates when it next starts.",
                                         Server.short(server.running), Server.short(server.bundled))
        }
        return UpdaterStrings.format("components.acpmux.behind",
                                     "acpmux: runs %1$@, this app has %2$@. Update All restarts it; every agent keeps running.",
                                     Server.short(server.running), Server.short(server.bundled))
    }

    private var agentCLIsLine: String {
        guard let outdated = outdatedAgentCLIs else {
            return UpdaterStrings.text("components.agents.unknown", "Agent CLIs: not checked. acpmux did not answer.")
        }
        guard !outdated.isEmpty else { return UpdaterStrings.text("components.agents.current", "Agent CLIs: up to date.") }
        return UpdaterStrings.format("components.agents.outdated", "Agent CLIs: %@ can be updated. Update All updates them.",
                                     ListFormatter.localizedString(byJoining: outdated))
    }
}

/// Update All's result lines, one per part it ran.
extension ComponentStatus {
    public static func acpmuxUpdated(_ check: Server?) -> String {
        guard let check, check.running != nil, !check.isBehind else {
            return UpdaterStrings.format("components.result.acpmuxStill", "acpmux still runs %@.", Server.short(check?.running))
        }
        return UpdaterStrings.format("components.result.acpmux", "acpmux now runs %@.", Server.short(check.running))
    }

    public static func acpmuxFailed(_ reason: String) -> String {
        UpdaterStrings.format("components.result.acpmuxFailed", "acpmux didn't restart: %@", reason)
    }

    public static var agentCLIsStarted: String {
        UpdaterStrings.text("components.result.agents", "Agent CLI updates run in a terminal tab.")
    }

    public static var appInstalling: String {
        UpdaterStrings.text("components.result.app", "cmux installs its update and restarts when no agent is busy.")
    }

    public static func appFailed(_ reason: String) -> String {
        UpdaterStrings.format("components.result.appFailed", "cmux couldn't install its update: %@", reason)
    }
}
