import AppKit
import CmuxNextBrowser
import class CmuxNextDaemon.PaneModel
import CmuxNextHistory
import Foundation

/// The restore actions of history entries (plans/cmux-next/history.md 5):
/// one path for the history page, the palette pages and the CLI.
@MainActor
struct HistoryRestorer {
    let services: AppServices

    /// Runs the entry's primary action. `newTab` opens a page beside the
    /// focused tab instead of in it.
    func open(_ entry: HistoryEntry, newTab: Bool = false) {
        // From a top page (History on top): the entry opens in the window's workspace.
        let leftPage = TopPages.leave(services)
        switch entry.payload {
        case .page(let url, let profile): openPage(url, profile: profile, newTab: newTab || leftPage)
        case .location(let location, _):
            if !services.locationTrail.goTo(location) { services.registry.refuse(HistoryAppStrings.entryGone) }
        case .closed(let item): reopen(item)
        case .agent(let session): resume(session)
        case .command(let command): runAgain(command)
        }
    }

    func openPage(_ text: String, profile: String?, newTab: Bool) {
        guard let url = URL(string: text) else { return }
        let leftPage = TopPages.leave(services)
        let newTab = newTab || leftPage
        let window = services.windows.active
        let pane = window?.focusedPane ?? window?.content?.panes.values.first
        if !newTab, let pane, let tab = pane.selectedTab, tab.kind == .browser,
           let page = services.cache.existingBrowser(tab.id)?.tab {
            page.load(url)
            return
        }
        guard let pane else {
            services.registry.refuse(RefusalStrings.noWindowOpen)
            return
        }
        pane.newBrowserTab(url: url, profile: profile)
    }

    /// Reopens a closed tab, screen or workspace from a history list, on the
    /// daemon that recorded it (the only closed history).
    func reopen(_ item: ClosedItem) {
        reopen(closedID: item.id)
    }

    /// Reopens one closed item by its history id (`nil`: the newest one of
    /// the key window, as Cmd-Shift-T picks it).
    func reopen(closedID: String?) {
        let entry: DaemonClosedHistory.Entry?
        if let closedID {
            entry = DaemonClosedHistory.entry(DaemonClosedHistory.daemonID(fromHistoryID: closedID) ?? closedID, in: services)
        } else {
            entry = DaemonClosedHistory.newest(for: services.windows.active?.state.id, in: services)
        }
        guard let entry else {
            services.registry.refuse(closedID == nil ? HistoryAppStrings.nothingClosed : HistoryAppStrings.entryGone)
            return
        }
        DaemonClosedHistory.reopen(entry, services: services)
    }

    /// Resumes an agent session in a new terminal tab on its machine, in
    /// its directory: in the tab's old pane when it still exists, else the
    /// focused pane when it is on that machine.
    func resume(_ session: AgentSession) {
        // A session still running shows its terminal instead of a second resume.
        if session.endedAt == nil, let harness = TerminalChatRoute.harness(of: session.provider),
           services.revealAgentSession(harness: harness, session: session.sessionID) { return }
        guard let command = session.resumeCommand else { return services.registry.refuse(HistoryAppStrings.noResume) }
        guard services.machines.daemons.contains(where: { $0.machineID == session.machine }) else {
            return services.registry.refuse(HistoryAppStrings.machineOffline)
        }
        let old = paneForResume(session).flatMap { services.paneController(for: $0) }
        let focused = services.windows.active?.focusedPane.flatMap { pane in
            services.daemon(for: pane.pane).machineID == session.machine ? pane : nil
        }
        guard let pane = old ?? focused else { return services.registry.refuse(HistoryAppStrings.noPane) }
        pane.newTerminalTab(cwd: session.cwd, typing: command + "\n")
    }

    /// Resolves the old pane for a history session on the session's machine.
    /// A duplicate tab id on another machine must never redirect a resume.
    func paneForResume(_ session: AgentSession) -> PaneModel? {
        session.tab.flatMap { services.locateTab($0, onMachine: session.machine)?.1 }
    }

    /// Runs a command again in a new terminal tab, in its directory, on its
    /// machine (the focused pane when it is there, else its machine's first
    /// shown pane).
    func runAgain(_ command: TerminalCommand) {
        guard let text = command.command else { return services.registry.refuse(HistoryAppStrings.entryGone) }
        guard services.machines.daemons.contains(where: { $0.machineID == command.machine }) else {
            return services.registry.refuse(HistoryAppStrings.machineOffline)
        }
        let onMachine = { (pane: PaneController) in services.daemon(for: pane.pane).machineID == command.machine }
        let focused = services.windows.active?.focusedPane.flatMap { onMachine($0) ? $0 : nil }
        let shown = services.windows.controllers.lazy.compactMap { $0.content?.panes.values.first(where: onMachine) }.first
        guard let pane = focused ?? shown else { return services.registry.refuse(HistoryAppStrings.noPane) }
        pane.newTerminalTab(cwd: command.cwd, typing: text + "\n")
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
