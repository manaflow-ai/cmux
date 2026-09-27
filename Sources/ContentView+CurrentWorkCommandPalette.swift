import CmuxCloud
import AppKit
import CmuxCommandPalette

private typealias CurrentWorkPaletteFocusTarget = (windowID: UUID, manager: TabManager, workspaceID: UUID, panelID: UUID)

extension ContentView {
    static func commandPaletteFindWorkContribution() -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: "palette.findWork",
            title: { _ in String(localized: "commandPalette.currentWork.title", defaultValue: "Find Work") },
            subtitle: { _ in String(localized: "commandPalette.currentWork.subtitle", defaultValue: "Current local and Cloud work") },
            keywords: ["current", "work", "find", "agent", "attention", "cloud", "pull request"],
            dismissOnRun: false
        )
    }

    func commandPaletteCurrentWorkEntries(snapshot: CurrentWorkSnapshot) -> [CommandPaletteCommand] {
        let targets = currentWorkPaletteFocusTargets()
        var entries = snapshot.items.enumerated().map { index, item in
            let canFocus = currentWorkPaletteFocusTarget(item: item, targets: targets) != nil
            return CommandPaletteCommand(
                id: "palette.currentWork." + item.resourceRef,
                rank: index,
                title: item.label,
                subtitle: CurrentWorkPalettePresentation(item: item).subtitle(canFocus: canFocus),
                shortcutHint: nil,
                kindLabel: item.placement.kind == "local"
                    ? String(localized: "commandPalette.currentWork.local", defaultValue: "Local")
                    : String(localized: "commandPalette.currentWork.cloud", defaultValue: "Cloud"),
                keywords: [item.resourceRef, item.kind, item.placement.machine]
                    + item.projectHints + item.agents.compactMap(\.kind)
                    + item.agents.map(\.state) + item.attention.map(\.kind)
                    + item.pullRequests.map { "PR \($0.number) \($0.label) \($0.status)" },
                dismissOnRun: canFocus,
                action: {
                    // Snapshot rows are observations, never navigation authority.
                    guard canFocus, let target = currentWorkPaletteFocusTarget(item: item, targets: currentWorkPaletteFocusTargets()) else {
                        NSSound.beep()
                        return
                    }
                    focusCommandPaletteSwitcherSurfaceTarget(
                        windowId: target.windowID, tabManager: target.manager,
                        workspaceId: target.workspaceID, panelId: target.panelID
                    )
                }
            )
        }
        if snapshot.truncated {
            entries.append(CommandPaletteCommand(
                id: "palette.currentWork.truncated", rank: entries.count,
                title: String(format: String(localized: "commandPalette.currentWork.truncated", defaultValue: "Showing %lld of %lld items"), Int64(snapshot.items.count), Int64(snapshot.totalObserved)),
                subtitle: String(localized: "commandPalette.currentWork.bounded", defaultValue: "Additional work is outside this snapshot."),
                shortcutHint: nil, kindLabel: nil, keywords: [], dismissOnRun: false, action: {}
            ))
        }
        return entries
    }

    private func currentWorkPaletteFocusTargets() -> [UUID: CurrentWorkPaletteFocusTarget] {
        let contexts = AppDelegate.shared?.listMainWindowSummaries().compactMap { summary in
            AppDelegate.shared?.tabManagerFor(windowId: summary.windowId).map { (summary.windowId, $0) }
        } ?? [(windowId, tabManager)]
        var targets: [UUID: CurrentWorkPaletteFocusTarget] = [:]
        for (windowID, manager) in contexts {
            for workspace in manager.tabs {
                for panelID in workspace.panels.keys {
                    targets[panelID] = (windowID, manager, workspace.id, panelID)
                }
            }
        }
        return targets
    }

    private func currentWorkPaletteFocusTarget(
        item: CurrentWorkSnapshot.Item,
        targets: [UUID: CurrentWorkPaletteFocusTarget]
    ) -> CurrentWorkPaletteFocusTarget? {
        for projection in item.projections {
            guard let current = SurfaceCatalog.shared.projection(forPanel: projection.panelID),
                  CurrentWorkPalettePresentation(item: item).matches(projection: projection, current: current),
                  let target = targets[current.panelID], target.workspaceID == current.workspaceID else { continue }
            return target
        }
        return nil
    }

    func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        // Defer focus mutation one turn so browser omnibar autofocus can run
        // without being blocked by the palette-visibility guard.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(
                workspaceId,
                suppressFlash: true,
                dismissRestoredUnreadOnResume: true
            )
        }
    }

    func focusCommandPaletteSwitcherSurfaceTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID
    ) {
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(
                workspaceId,
                surfaceId: panelId,
                suppressFlash: true,
                dismissRestoredUnreadOnResume: true
            )
        }
    }

}
