#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct TerminalPickerMenuPresentationTests {
    @Test func updatesLeavePresentedMenuAloneAndNextOpeningUsesCurrentRows() throws {
        let initial = menuValue(generation: 0)
        let coordinator = TerminalPickerMenuButton.Coordinator(value: initial, actions: actions())
        let button = UIButton(type: .custom)
        button.menu = coordinator.menu
        let installedMenu = try #require(button.menu)
        let presented = coordinator.makeMenuElements()
        let before = menuActions(in: presented)

        for generation in 1...20 {
            TerminalPickerMenuButton(value: menuValue(generation: generation), actions: actions())
                .update(button, coordinator: coordinator)
            #expect(button.menu === installedMenu)
        }

        #expect(before.map(\.title) == menuActions(in: presented).map(\.title))
        #expect(before.contains { $0.title == "Terminal 0" })
        #expect(before.contains { $0.title == "Browser 0" })
        #expect(before.contains { $0.title == "Simulator 0" })
        #expect(!before.contains { $0.title == "Added terminal" })

        let reopened = menuActions(in: coordinator.makeMenuElements())
        #expect(reopened.contains { $0.title == "Terminal 20" })
        #expect(reopened.contains { $0.title == "Browser 20" })
        #expect(reopened.contains { $0.title == "Simulator 20" })
        #expect(reopened.contains { $0.title == "Added terminal" })
        #expect(button.accessibilityValue == "Terminal 20")
        #expect(reopened.first { $0.identifier.rawValue == "MobileTerminalMenuItem-terminal-1" }?.state == .on)
    }

    @Test func groupedTitlesAndActionAvailabilityAreCapturedTogether() throws {
        let coordinator = TerminalPickerMenuButton.Coordinator(
            value: menuValue(generation: 0, grouped: true), actions: actions()
        )
        let presented = coordinator.makeMenuElements()
        let before = menuActions(in: presented)
        coordinator.value = menuValue(generation: 1, grouped: true)
        let reopened = coordinator.makeMenuElements()
        let after = menuActions(in: reopened)

        #expect((presented.first as? UIMenu)?.title == "Window 0")
        #expect((reopened.first as? UIMenu)?.title == "Window 1")
        #expect(before.first?.title == "Pane 0")
        #expect(after.first?.title == "Pane 1")
        #expect(before.first?.subtitle == "Pane 1")
        #expect(before.first?.state == .on)
        #expect(before.contains { $0.title == "Split Right" })
        #expect(before.contains { $0.title == "New Window" })
        let createBefore = try #require(before.first { $0.identifier.rawValue == "MobileNewWorkspaceMenuItem" })
        let createAfter = try #require(after.first { $0.identifier.rawValue == "MobileNewWorkspaceMenuItem" })
        #expect(!createBefore.attributes.contains(.disabled))
        #expect(createAfter.attributes.contains(.disabled))
    }

    @Test func actionsKeepTheirPresentationTargetAndRefreshOnTheNextOpening() throws {
        var selected: [String] = []
        let value = menuValue(generation: 0)
        let coordinator = TerminalPickerMenuButton.Coordinator(
            value: value, actions: actions { selected.append("first:\($0.rawValue)") }
        )
        let before = try #require(menuActions(in: coordinator.makeMenuElements()).first)
        // Identical labels must still receive a new action target. An Equatable
        // view that ignores closures can otherwise keep an old workspace alive.
        coordinator.actions = actions { selected.append("second:\($0.rawValue)") }
        let after = try #require(menuActions(in: coordinator.makeMenuElements()).first)
        let firstButton = UIButton(type: .custom)
        firstButton.addAction(before, for: .primaryActionTriggered)
        firstButton.sendActions(for: .primaryActionTriggered)
        let secondButton = UIButton(type: .custom)
        secondButton.addAction(after, for: .primaryActionTriggered)
        secondButton.sendActions(for: .primaryActionTriggered)
        #expect(selected == ["first:terminal-1", "second:terminal-1"])
    }

    private func menuValue(generation: Int, grouped: Bool = false) -> TerminalPickerMenuValue {
        var terminals = [MobileTerminalPreview(id: "terminal-1", name: "Terminal \(generation)")]
        if generation > 0 { terminals.append(MobileTerminalPreview(id: "terminal-2", name: "Added terminal")) }
        return TerminalPickerMenuValue(
            liveTerminals: terminals,
            selectedID: "terminal-1",
            canCreateWorkspace: generation == 0,
            hasActiveBrowser: false,
            browserStreamRows: [BrowserStreamPickerRow(MobileBrowserPanelDescriptor(
                panelID: "browser-1", workspaceID: "workspace-1", url: "https://cmux.com",
                title: "Browser \(generation)", pageWidth: 800, pageHeight: 600,
                canGoBack: false, canGoForward: false, isLoading: false
            ))],
            supportsBrowserStream: true,
            simulatorStreamRows: [SimulatorStreamPickerRow(MobileSimulatorPanelDescriptor(
                panelID: "simulator-1", workspaceID: "workspace-1", title: "Simulator",
                selectedDeviceName: "Simulator \(generation)", selectedDeviceState: "Booted",
                status: "ready", isReady: true, supportsTouch: true, supportsKeyboard: true,
                supportsHardwareButtons: true, supportsRotation: true
            ))],
            supportsSimulatorStream: true,
            sshTabLayout: grouped ? MobileSSHTabLayout(kind: .tmux, sections: [
                MobileSSHTabSection(
                    id: "window-1", title: "Window \(generation)", rows: [
                        MobileSSHTabRow(id: "terminal-1", title: "Pane \(generation)", paneLabel: "Pane 1", startsPane: false),
                    ], actions: [.splitRight, .splitDown]
                ),
            ]) : nil
        )
    }

    private func actions(
        selectTerminal: @escaping (MobileTerminalPreview.ID) -> Void = { _ in }
    ) -> TerminalPickerMenuActions {
        TerminalPickerMenuActions(
            selectTerminal: selectTerminal, selectMacSurface: { _ in },
            createWorkspace: {}, createTerminal: {}, openBrowser: {},
            selectBrowserStream: { _ in }, selectSimulatorStream: { _ in },
            openTextSheet: {}, copyDebugLogs: {}, sendFeedback: {}
        )
    }

    private func menuActions(in elements: [UIMenuElement]) -> [UIAction] {
        elements.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let menu = element as? UIMenu { return menuActions(in: menu.children) }
            return []
        }
    }
}
#endif
