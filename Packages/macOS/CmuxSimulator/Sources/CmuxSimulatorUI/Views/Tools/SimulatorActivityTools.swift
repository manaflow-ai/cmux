import CmuxSimulator
import SwiftUI

struct SimulatorActivityTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if coordinator.actionLog.isEmpty {
                            Text(simulatorStrings.noActivity)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(coordinator.actionLog) { entry in
                                SimulatorActivityEntryView(entry: entry)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            } label: {
                Text(simulatorStrings.activity)
                    .font(.headline)
            }
        }
        .controlSize(.small)
    }
}

private struct SimulatorActivityEntryView: View {
    let entry: SimulatorActionLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: entry.succeeded == false ? "xmark.circle.fill" : "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(entry.succeeded == false ? .red : .secondary)
                Text(simulatorStrings.actionLog(entry.action))
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup {
                Text(verbatim: entry.summary)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            } label: {
                Text(simulatorStrings.technicalDetails)
                    .font(.caption2)
            }
        }
    }
}
