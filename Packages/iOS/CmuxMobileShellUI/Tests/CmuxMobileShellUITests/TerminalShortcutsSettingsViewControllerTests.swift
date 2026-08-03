#if os(iOS)
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import Foundation
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite("Native terminal shortcuts settings")
struct TerminalShortcutsSettingsViewControllerTests {
    @Test @MainActor
    func rendersAndMutatesConfigurationThroughUIKitControls() throws {
        let configuration = makeConfiguration()
        let controller = TerminalShortcutsSettingsViewController(
            scope: .terminal,
            configuration: configuration
        )
        controller.loadViewIfNeeded()

        #expect(controller.numberOfSections(in: controller.tableView) == 3)
        #expect(controller.tableView(controller.tableView, numberOfRowsInSection: 0) == configuration.displayItems.count)
        #expect(controller.navigationItem.leftBarButtonItem?.accessibilityIdentifier == "TerminalShortcutsEditButton")
        #expect(controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier == "TerminalShortcutsDoneButton")

        let firstItem = try #require(configuration.displayItems.first)
        let indexPath = IndexPath(row: 0, section: 0)
        let cell = try #require(
            controller.tableView(controller.tableView, cellForRowAt: indexPath) as? TerminalShortcutToggleCell
        )
        #expect(cell.toggle.accessibilityIdentifier == "TerminalShortcutToggle.\(firstItem.id.storageKey)")

        let oldValue = configuration.isEnabled(firstItem.id)
        cell.toggle.isOn = !oldValue
        cell.toggle.sendActions(for: .valueChanged)
        #expect(configuration.isEnabled(firstItem.id) == !oldValue)
    }

    @Test @MainActor
    func editorPreservesIdentityAndBuildsSubmittedText() throws {
        let id = UUID()
        let existing = CustomToolbarAction(
            id: id,
            title: "Old",
            payload: .text("pwd")
        )
        var saved: CustomToolbarAction?
        let controller = CustomToolbarActionEditorViewController(action: existing) {
            saved = $0
        }
        controller.loadViewIfNeeded()

        controller.titleField.text = "  Deploy  "
        controller.commandCell.textView.text = "make deploy"
        controller.runAfterTypingSwitch.isOn = true
        controller.saveAction()

        let action = try #require(saved)
        #expect(action.id == id)
        #expect(action.title == "Deploy")
        #expect(action.payload == .text("make deploy\n"))
    }

    @MainActor
    private func makeConfiguration() -> TerminalAccessoryConfiguration {
        let suite = "TerminalShortcutsSettingsViewControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TerminalAccessoryConfiguration(defaults: defaults)
    }
}
#endif
