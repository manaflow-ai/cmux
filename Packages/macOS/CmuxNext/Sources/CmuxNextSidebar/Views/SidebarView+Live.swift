import AppKit
import CmuxNextCompat
public import CmuxNextSettings
import OSLog
import CmuxNextDesign

/// The footer's Live button (Leo 2026-11-24: "an icon maybe toggle somewhere omnipresent... say the bottom left of
/// the sidebar area, which is currently not used for anything. because we hid spaces by default"): a click turns
/// `presence.live` on or off through ``onLiveToggle``, a right-click lists who is live. On it is accent-filled, off
/// it is dimmed; `sidebar.showLiveToggle` hides it.
extension SidebarView {
    /// The button's look and tooltip for the current ``live`` state.
    func applyLive() {
        liveButton.tintOverride = live.isLive ? Palette.litGlyph : Palette.textTertiary
        liveButton.alphaValue = live.isLive ? 1 : 0.7
        liveButton.themedToolTip = Strings.liveTooltip(isLive: live.isLive, teammatesLive: live.teammatesLive)
        liveButton.setAccessibilityValue(live.isLive ? "1" : "0")
        liveButton.setAccessibilityHelp(liveButton.themedToolTip)
    }

    /// The agents working now in any workspace, each once: their name and the workspace and tab a click goes to.
    func liveAgents() -> [(presence: SidebarPresence, workspace: WorkspaceID)] {
        var seen: Set<String> = []
        return model.allWorkspaces.flatMap { ws in ws.presence.map { ($0, ws.id) } }.filter { seen.insert($0.0.id).inserted }
    }

    /// The right-click menu: agents working now, the team's people (live first), then Turn Live Off or On.
    func liveMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = liveMenuTarget
        func add(_ title: String, _ run: (() -> Void)?) {
            let item = NSMenuItem(title: title, action: run == nil ? nil : #selector(SidebarLiveMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = run.map { SidebarLiveMenuTarget.Run(run: $0) }
            item.isEnabled = run != nil
            menu.addItem(item)
        }
        func header(_ title: String) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let agents = liveAgents()
        if !agents.isEmpty {
            header(Strings.liveAgents)
            for (presence, workspace) in agents {
                add(presence.name) { [weak self] in
                    guard let tab = presence.tab else { self?.model.send(.select(workspace)); return }
                    self?.model.send(.selectTab(workspace: workspace, tab: tab))
                }
            }
        }
        if !live.people.isEmpty {
            header(Strings.liveTeammates)
            for person in live.people.sorted(by: { ($0.isLive ? 0 : 1, $0.name) < ($1.isLive ? 0 : 1, $1.name) }) {
                add((person.isLive ? "● " : "") + person.name) { [weak self] in self?.onLiveOpenPerson?(person.name) }
            }
        }
        if agents.isEmpty && live.teammatesLive == 0 {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            add(Strings.liveNobody, nil)
        }
        menu.addItem(.separator())
        add(live.isLive ? Strings.liveTurnOff : Strings.liveTurnOn) { [weak self] in self?.onLiveToggle?() }
        return menu
    }
}

/// The menu rows' target: each row carries the closure it runs.
@MainActor
final class SidebarLiveMenuTarget: NSObject {
    final class Run { let run: () -> Void; init(run: @escaping () -> Void) { self.run = run } }
    @objc func pick(_ item: NSMenuItem) { (item.representedObject as? Run)?.run() }
}

extension SidebarView {
    /// Wires the Live button to `presence.live` and the team: the state follows the setting (Observation), a click flips
    /// the setting (the daemon reads the same key), a person opens through `open`. `liveIDs` is the seam for the live
    /// feed (`_acpmux/live_list`, RFD 0141 phase 1): empty until it lands, so nobody is marked live yet.
    public func bindLive(settings: @escaping @MainActor () -> SettingsController?, team: @escaping @MainActor () -> [(id: String, name: String)],
                         liveIDs: @escaping @MainActor () -> Set<String> = { [] }, open: @escaping (String) -> Void) {
        let state: @MainActor () -> SidebarLiveState = {
            SidebarLiveState(isLive: settings()?.snapshot.sidebarSections.presenceLive ?? false, team: team(), liveIDs: liveIDs())
        }
        live = state()
        onLiveOpenPerson = open
        onLiveToggle = {
            guard let settings = settings() else { return }
            let next = !settings.snapshot.sidebarSections.presenceLive, writer = SettingWriter.currentRun()
            // task-owner: one write; ends when the file has it
            Task {
                do { try await settings.setSetting(at: SidebarSectionsSetting.presenceLivePath, to: .bool(next), by: writer) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar-live").error("presence.live write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        // task-owner: ends with the sidebar; event-driven (Observation)
        Task { [weak self] in
            for await next in ObservationStream(state) {
                guard let self else { return }
                if live != next { live = next }
            }
        }
    }
}
