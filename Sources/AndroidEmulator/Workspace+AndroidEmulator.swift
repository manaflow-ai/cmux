import Bonsplit
import CmuxAndroidEmulator
import CmuxAndroidEmulatorUI
import CmuxWorkspaces
import Foundation

extension Workspace {
    @discardableResult
    func openAndroidEmulatorPane(
        device: AndroidVirtualDevice,
        coordinator: AndroidEmulatorCoordinator
    ) -> AndroidEmulatorPanel? {
        guard case .running(let serial, _, let transportID) = device.state else { return nil }
        if let existing = panels.values.compactMap({ $0 as? AndroidEmulatorPanel }).first(where: {
            $0.controller.avdName == device.name && $0.controller.serial == serial
        }) {
            focusPanel(existing.id)
            return existing
        }

        let controller = AndroidEmulatorPaneController(
            avdName: device.name,
            serial: serial,
            transportID: transportID,
            coordinator: coordinator
        )
        guard let sourcePanelID = focusedPanelId else { return nil }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: sourcePanelID) {
            return newAndroidEmulatorSurface(inPane: targetPane, controller: controller, focus: true)
        }
        return newAndroidEmulatorSplit(
            from: sourcePanelID,
            orientation: .horizontal,
            controller: controller,
            focus: true
        )
    }

    @discardableResult
    func newAndroidEmulatorSurface(
        inPane paneID: PaneID,
        controller: AndroidEmulatorPaneController,
        focus: Bool
    ) -> AndroidEmulatorPanel? {
        let panel = AndroidEmulatorPanel(controller: controller)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        guard let tabID = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.androidEmulator.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneID
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }
        bindSurface(tabID, toPanelId: panel.id)
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneID,
            kind: SurfaceKind.androidEmulator.rawValue,
            origin: "android_emulator_tab",
            focused: focus
        )
        if focus {
            bonsplitController.focusPane(paneID)
            bonsplitController.selectTab(tabID)
            applyTabSelection(tabId: tabID, inPane: paneID)
        }
        return panel
    }

    @discardableResult
    private func newAndroidEmulatorSplit(
        from panelID: UUID,
        orientation: SplitOrientation,
        controller: AndroidEmulatorPaneController,
        focus: Bool
    ) -> AndroidEmulatorPanel? {
        guard let sourceTabID = surfaceIdFromPanelId(panelID),
              let sourcePaneID = bonsplitController.allPaneIds.first(where: { paneID in
                  bonsplitController.tabs(inPane: paneID).contains(where: { $0.id == sourceTabID })
              }) else {
            return nil
        }

        let panel = AndroidEmulatorPanel(controller: controller)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        let tab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.androidEmulator.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(tab.id, toPanelId: panel.id)
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let paneID = bonsplitController.splitPane(
            sourcePaneID,
            orientation: orientation,
            withTab: tab,
            insertFirst: false
        ) else {
            removeSurfaceMapping(forSurfaceId: tab.id)
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }
        publishCmuxSplitCreated(
            paneID,
            sourcePaneId: sourcePaneID,
            orientation: orientation,
            surfaceId: panel.id,
            kind: SurfaceKind.androidEmulator.rawValue,
            origin: "android_emulator_split",
            focused: focus
        )
        if focus {
            focusPanel(panel.id)
        }
        return panel
    }
}
