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
                    Task { await coordinator.installApplication() }
                }
                Button(simulatorStrings.refresh) {
                    Task { await coordinator.refreshApplications() }
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
                        Task {
                            await coordinator.launchApplication(
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
                        Task { await coordinator.terminateApplication(bundleIdentifier: selectedBundleIdentifier) }
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
