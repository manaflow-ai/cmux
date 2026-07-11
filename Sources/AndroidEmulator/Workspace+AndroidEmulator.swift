import Bonsplit
import CmuxAndroidEmulator
import CmuxAndroidEmulatorUI
import CmuxWorkspaces
import Foundation

extension Workspace {
    @discardableResult
    func openAndroidEmulatorPickerPane(
        coordinator: AndroidEmulatorCoordinator
    ) -> AndroidEmulatorPanel? {
        if let existing = panels.values.compactMap({ $0 as? AndroidEmulatorPanel })
            .first(where: \.isSelectingDevice) {
            focusPanel(existing.id)
            return existing
        }
        guard let sourcePanelID = focusedPanelId else { return nil }
        let panel = AndroidEmulatorPanel(coordinator: coordinator)
        if let targetPane = preferredRightSideTargetPane(fromPanelId: sourcePanelID) {
            return newAndroidEmulatorSurface(inPane: targetPane, panel: panel, focus: true)
        }
        return newAndroidEmulatorSplit(
            from: sourcePanelID,
            orientation: .horizontal,
            panel: panel,
            focus: true
        )
    }

    @discardableResult
    func openAndroidEmulatorPane(
        device: AndroidVirtualDevice,
        sdkRootURL: URL,
        coordinator: AndroidEmulatorCoordinator
    ) -> AndroidEmulatorPanel? {
        guard case .running(let serial, _, let transportID) = device.state else { return nil }
        if let existing = panels.values.compactMap({ $0 as? AndroidEmulatorPanel }).first(where: {
            $0.controller?.avdName == device.name
                && $0.controller?.serial == serial
                && $0.controller?.transportID == transportID
        }) {
            focusPanel(existing.id)
            return existing
        }
        if let stale = panels.values.compactMap({ $0 as? AndroidEmulatorPanel }).first(where: {
            $0.controller?.avdName == device.name && $0.controller?.serial == serial
        }) {
            _ = closePanel(stale.id, force: true)
        }

        if let picker = panels.values.compactMap({ $0 as? AndroidEmulatorPanel })
            .first(where: \.isSelectingDevice) {
            picker.select(device)
            updateAndroidEmulatorPanelMetadata(picker)
            focusPanel(picker.id)
            return picker
        }

        let controller = AndroidEmulatorPaneController(
            avdName: device.name,
            serial: serial,
            transportID: transportID,
            sdkRootURL: sdkRootURL,
            coordinator: coordinator
        )
        let panel = AndroidEmulatorPanel(coordinator: coordinator, controller: controller)
        guard let sourcePanelID = focusedPanelId else { return nil }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: sourcePanelID) {
            return newAndroidEmulatorSurface(inPane: targetPane, panel: panel, focus: true)
        }
        return newAndroidEmulatorSplit(
            from: sourcePanelID,
            orientation: .horizontal,
            panel: panel,
            focus: true
        )
    }

    @discardableResult
    func newAndroidEmulatorSurface(
        inPane paneID: PaneID,
        panel: AndroidEmulatorPanel,
        focus: Bool
    ) -> AndroidEmulatorPanel? {
        bindAndroidEmulatorPanelLifecycle(panel)
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
        panel: AndroidEmulatorPanel,
        focus: Bool
    ) -> AndroidEmulatorPanel? {
        guard let sourceTabID = surfaceIdFromPanelId(panelID),
              let sourcePaneID = bonsplitController.allPaneIds.first(where: { paneID in
                  bonsplitController.tabs(inPane: paneID).contains(where: { $0.id == sourceTabID })
              }) else {
            return nil
        }

        bindAndroidEmulatorPanelLifecycle(panel)
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

    private func updateAndroidEmulatorPanelMetadata(_ panel: AndroidEmulatorPanel) {
        panelTitles[panel.id] = panel.displayTitle
        guard let tabID = surfaceIdFromPanelId(panel.id) else { return }
        bonsplitController.updateTab(tabID, title: panel.displayTitle, icon: panel.displayIcon)
    }

    private func bindAndroidEmulatorPanelLifecycle(_ panel: AndroidEmulatorPanel) {
        panel.onDisplayTitleChange = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            updateAndroidEmulatorPanelMetadata(panel)
        }
        panel.setStopConfirmedHandler { [weak self, weak panel] in
            guard let self, let panel else { return }
            _ = self.closePanel(panel.id, force: true)
        }
    }
}
