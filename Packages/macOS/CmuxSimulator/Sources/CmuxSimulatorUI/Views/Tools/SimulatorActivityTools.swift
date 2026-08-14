import CmuxSimulator
import SwiftUI

struct SimulatorActivityTools: View {
    let entries: [SimulatorActionLogEntry]
    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if entries.isEmpty {
                            Text(simulatorStrings.noActivity)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(entries) { entry in
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
