import SwiftUI

struct SimulatorLogTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var bundleIdentifier = ""

    var body: some View {
        SimulatorToolSection(simulatorStrings.logs) {
            TextField(String(localized: simulatorStrings.bundleIdentifier), text: $bundleIdentifier)
            HStack {
                Button(simulatorStrings.recentLogs) {
                    coordinator.scheduleControlAction("load-recent-logs") {
                        await $0.loadRecentLogs(bundleIdentifier: bundleIdentifier)
                    }
                }
                Button(coordinator.isStreamingLogs ? simulatorStrings.stopLogStream : simulatorStrings.startLogStream) {
                    coordinator.scheduleControlAction("toggle-log-stream") {
                        await $0.toggleLogStream(bundleIdentifier: bundleIdentifier)
                    }
                }
            }
            if !displayedLogs.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: displayedLogs)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
        }
    }

    private var displayedLogs: String {
        coordinator.isStreamingLogs ? coordinator.liveLogsText : coordinator.recentLogsText
    }
}
