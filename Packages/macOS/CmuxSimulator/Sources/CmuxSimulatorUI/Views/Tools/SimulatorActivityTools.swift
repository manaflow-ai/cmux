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
