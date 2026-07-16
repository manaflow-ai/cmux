import CmuxSimulator
import SwiftUI

struct SimulatorApplicationTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var selectedBundleIdentifier = ""
    @State private var arguments = ""
    @State private var terminateRunning = true
    @State private var waitForDebugger = false

    var body: some View {
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
            if !coordinator.installedApplications.isEmpty {
                Picker(simulatorStrings.applications, selection: $selectedBundleIdentifier) {
                    ForEach(coordinator.installedApplications) { application in
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
