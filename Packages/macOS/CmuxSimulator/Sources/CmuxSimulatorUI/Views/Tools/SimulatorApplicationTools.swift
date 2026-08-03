import AppKit
import CmuxSimulator

@MainActor
final class SimulatorApplicationTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let picker = SimulatorClosurePopUpButton()
    private let arguments = SimulatorClosureTextField()
    private let terminateRunning = SimulatorClosureSwitch(
        title: String(localized: simulatorStrings.terminateRunning)
    )
    private let waitForDebugger = SimulatorClosureSwitch(
        title: String(localized: simulatorStrings.waitForDebugger)
    )
    private let launchButton = SimulatorClosureButton(title: String(localized: simulatorStrings.launch))
    private let terminateButton = SimulatorClosureButton(title: String(localized: simulatorStrings.terminate))
    private var pickerSignature = ""
    private var selectedBundleIdentifier = ""
    private var lastHydratedDeviceID: String?

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.applications)
        terminateRunning.state = .on
        let install = SimulatorClosureButton(title: String(localized: simulatorStrings.installApplication)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("install-application") { await $0.installApplication() }
        }
        let refresh = SimulatorClosureButton(title: String(localized: simulatorStrings.refresh)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("refresh-applications") { await $0.refreshApplications() }
        }
        add(simulatorRow([install, refresh]))
        picker.handler = { [weak self] _ in
            self?.selectedBundleIdentifier = self?.picker.selectedItem?.representedObject as? String ?? ""
            self?.update()
        }
        add(picker)
        arguments.placeholderString = String(localized: simulatorStrings.launchArguments)
        add(arguments)
        add(terminateRunning)
        add(waitForDebugger)
        launchButton.handler = { [weak self] in self?.launch() }
        terminateButton.handler = { [weak self] in self?.terminate() }
        add(simulatorRow([launchButton, terminateButton]))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        if lastHydratedDeviceID != coordinator.selectedDeviceID {
            lastHydratedDeviceID = coordinator.selectedDeviceID
            Task { @MainActor [weak coordinator] in await coordinator?.refreshApplications() }
        }
        let rows = simulatorApplicationPickerRows(coordinator.installedApplications)
        let signature = rows.map { "\($0.id):\($0.displayName)" }.joined(separator: "|")
        if signature != pickerSignature {
            pickerSignature = signature
            picker.removeAllItems()
            for row in rows {
                picker.addItem(withTitle: row.displayName)
                picker.lastItem?.representedObject = row.id
            }
            if !rows.contains(where: { $0.id == selectedBundleIdentifier }) {
                selectedBundleIdentifier = rows.first?.id ?? ""
            }
            if let index = rows.firstIndex(where: { $0.id == selectedBundleIdentifier }) {
                picker.selectItem(at: index)
            }
        }
        let hasSelection = !selectedBundleIdentifier.isEmpty
        picker.isHidden = rows.isEmpty
        arguments.isHidden = rows.isEmpty
        terminateRunning.isHidden = rows.isEmpty
        waitForDebugger.isHidden = rows.isEmpty
        launchButton.isEnabled = hasSelection
        terminateButton.isEnabled = hasSelection
    }

    private func launch() {
        let bundleIdentifier = selectedBundleIdentifier
        let configuration = SimulatorLaunchConfiguration(
            arguments: arguments.stringValue.split(whereSeparator: \.isWhitespace).map(String.init),
            terminateRunningProcess: terminateRunning.state == .on,
            waitForDebugger: waitForDebugger.state == .on
        )
        coordinator.scheduleControlAction("launch-application") {
            await $0.launchApplication(bundleIdentifier: bundleIdentifier, configuration: configuration)
        }
    }

    private func terminate() {
        let bundleIdentifier = selectedBundleIdentifier
        coordinator.scheduleControlAction("terminate-application") {
            await $0.terminateApplication(bundleIdentifier: bundleIdentifier)
        }
    }
}

func simulatorApplicationPickerRows(
    _ applications: [SimulatorInstalledApplication]
) -> [SimulatorApplicationPickerRow] {
    applications.map {
        SimulatorApplicationPickerRow(id: $0.id, displayName: $0.displayName)
    }
}
