import CmuxSimulator
import SwiftUI

struct SimulatorApplicationTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var selectedBundleIdentifier = ""
    @State private var arguments = ""
    @State private var terminateRunning = true
    @State private var waitForDebugger = false

    var body: some View {
        let applicationRows = simulatorApplicationPickerRows(coordinator.installedApplications)
        SimulatorToolSection(simulatorStrings.applications) {
            HStack {
                Button(simulatorStrings.installApplication) {
                    coordinator.scheduleControlAction("install-application") {
                        await $0.installApplication()
                    }
                }
                Button(simulatorStrings.refresh) {
                    coordinator.scheduleControlAction("refresh-applications") {
                        await $0.refreshApplications()
                    }
                }
            }
            if !applicationRows.isEmpty {
                Picker(simulatorStrings.applications, selection: $selectedBundleIdentifier) {
                    ForEach(applicationRows) { application in
                        Text(verbatim: application.displayName).tag(application.id)
                    }
                }
                TextField(String(localized: simulatorStrings.launchArguments), text: $arguments)
                Toggle(simulatorStrings.terminateRunning, isOn: $terminateRunning)
                Toggle(simulatorStrings.waitForDebugger, isOn: $waitForDebugger)
                HStack {
                    Button(simulatorStrings.launch) {
                        coordinator.scheduleControlAction("launch-application") {
                            await $0.launchApplication(
                                bundleIdentifier: selectedBundleIdentifier,
                                configuration: SimulatorLaunchConfiguration(
                                    arguments: arguments.split(whereSeparator: \.isWhitespace).map(String.init),
                                    terminateRunningProcess: terminateRunning,
                                    waitForDebugger: waitForDebugger
                                )
                            )
                        }
                    }
                    Button(simulatorStrings.terminate) {
                        coordinator.scheduleControlAction("terminate-application") {
                            await $0.terminateApplication(bundleIdentifier: selectedBundleIdentifier)
                        }
                    }
                }
                .disabled(selectedBundleIdentifier.isEmpty)
            }
        }
        .task(id: coordinator.selectedDeviceID) {
            await coordinator.refreshApplications()
            selectedBundleIdentifier = coordinator.installedApplications.first?.id ?? ""
        }
        .onChange(of: coordinator.installedApplications) { _, applications in
            if !applications.contains(where: { $0.id == selectedBundleIdentifier }) {
                selectedBundleIdentifier = applications.first?.id ?? ""
            }
        }
    }
}

struct SimulatorApplicationPickerRow: Equatable, Identifiable {
    let id: String
    let displayName: String
}

func simulatorApplicationPickerRows(
    _ applications: [SimulatorInstalledApplication]
) -> [SimulatorApplicationPickerRow] {
    applications.map {
        SimulatorApplicationPickerRow(id: $0.id, displayName: $0.displayName)
    }
}
