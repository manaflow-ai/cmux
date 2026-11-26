#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceMacTitlePickerMenuTests {
    @Test func refreshesLeaveOpenMenuAloneAndNextOpeningUsesCurrentComputers() throws {
        let coordinator = WorkspaceMacTitlePickerMenuButton.Coordinator(value: value(generation: 0), actions: actions())
        let button = UIButton(type: .custom)
        button.menu = coordinator.menu
        let installedMenu = try #require(button.menu)
        let presented = coordinator.makeMenuElements()
        let initialTitles = menuActions(in: presented).map(\.title)

        for generation in 1...20 {
            WorkspaceMacTitlePickerMenuButton(
                value: value(generation: generation),
                actions: actions(),
                accessibilityLabel: "Computer 0 refresh \(generation)",
                accessibilityValue: generation.isMultiple(of: 2) ? "Reconnecting…" : ""
            ).update(button, coordinator: coordinator)
            #expect(button.menu === installedMenu)
            #expect(menuActions(in: presented).map(\.title) == initialTitles)
        }

        let reopened = menuActions(in: coordinator.makeMenuElements())
        #expect(reopened.contains { $0.title == "Computer 24 refresh 20" })
        #expect(!reopened.contains { $0.title == "Computer 24 refresh 0" })
        #expect(button.accessibilityLabel == "Computer 0 refresh 20")
        #expect(button.accessibilityValue == "Reconnecting…")
    }

    @Test func selectionSubtitlesAndAddComputerAreCapturedTogether() throws {
        let coordinator = WorkspaceMacTitlePickerMenuButton.Coordinator(value: value(generation: 0), actions: actions())
        let presented = coordinator.makeMenuElements()
        coordinator.value = value(generation: 1)
        let before = menuActions(in: presented)
        let after = menuActions(in: coordinator.makeMenuElements())
        let first = try #require(before.first { $0.identifier.rawValue == "MobileWorkspaceMacPickerMachine-mac-0-default" })
        #expect(first.title == "Computer 0 refresh 0")
        #expect(first.subtitle == "Nightly")
        #expect(first.state == .on)
        #expect(first.accessibilityIdentifier == "MobileWorkspaceMacPickerMachine-mac-0-default")
        #expect(before.first?.identifier.rawValue == "MobileWorkspaceMacPickerAll")
        #expect(before.first?.state == .off)
        #expect(after.first?.state == .on)
        #expect(after.dropFirst().allSatisfy { $0.state == .off })
        #expect(after.dropFirst().first?.subtitle == "Stable")
        let addSection = try #require(presented.last as? UIMenu)
        #expect(addSection.options.contains(.displayInline))
        #expect(addSection.children.first?.title == "Add Computer")
        #expect(!after.contains { $0.identifier.rawValue == "MobileWorkspaceMacPickerAdd" })
    }

    @Test func callbacksStayWithTheirOpeningAndRefreshEvenWhenValuesAreEqual() throws {
        var selections: [(String, WorkspaceMacSelection)] = []
        var additions: [String] = []
        let value = value(generation: 0)
        let coordinator = WorkspaceMacTitlePickerMenuButton.Coordinator(
            value: value,
            actions: WorkspaceMacTitlePickerActions(
                select: { selections.append(("first", $0)) },
                addDevice: { additions.append("first") }
            )
        )
        let before = menuActions(in: coordinator.makeMenuElements())
        WorkspaceMacTitlePickerMenuButton(
            value: value,
            actions: WorkspaceMacTitlePickerActions(
                select: { selections.append(("second", $0)) },
                addDevice: { additions.append("second") }
            ),
            accessibilityLabel: "Computer 0",
            accessibilityValue: ""
        ).update(UIButton(type: .custom), coordinator: coordinator)
        let after = menuActions(in: coordinator.makeMenuElements())

        for opening in [before, after] {
            send(try #require(opening.first))
            send(try #require(opening.first { $0.title == "Computer 24 refresh 0" }))
            send(try #require(opening.first { $0.identifier.rawValue == "MobileWorkspaceMacPickerAdd" }))
        }
        #expect(selections.map(\.0) == ["first", "first", "second", "second"])
        #expect(selections.map(\.1) == [.all, .machine(machineID(24)), .all, .machine(machineID(24))])
        #expect(additions == ["first", "second"])
    }

    private func value(generation: Int) -> WorkspaceMacTitlePickerMenuValue {
        WorkspaceMacTitlePickerMenuValue(
            selection: generation == 0 ? .machine(machineID(0)) : .all,
            machines: (0..<25).map { index in
                WorkspaceFilterMachine(
                    id: machineID(index), macDeviceID: "mac-\(index)", instanceTag: "default",
                    name: "Computer \(index) refresh \(generation)",
                    buildLabel: generation == 0 ? "Nightly" : "Stable"
                )
            },
            canAddDevice: generation == 0
        )
    }

    private func machineID(_ index: Int) -> String { "mac-\(index)\u{1F}default" }

    private func actions() -> WorkspaceMacTitlePickerActions {
        WorkspaceMacTitlePickerActions(select: { _ in }, addDevice: {})
    }

    private func send(_ action: UIAction) {
        let button = UIButton(type: .custom)
        button.addAction(action, for: .primaryActionTriggered)
        button.sendActions(for: .primaryActionTriggered)
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
