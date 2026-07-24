import CmuxSimulator
import SwiftUI

struct SimulatorWebInspectorTargetPicker: View {
    let isAvailable: Bool
    let targets: [SimulatorWebInspectorTarget]
    let session: SimulatorWebInspectorSessionStatus
    let refresh: () -> Void
    let attach: (String) -> Void
    let release: () -> Void

    var body: some View {
        HStack {
            Button(simulatorStrings.refreshTargets, action: refresh)
                .disabled(!isAvailable)
            Menu {
                ForEach(targets) { target in
                    Button {
                        attach(target.id)
                    } label: {
                        Text(verbatim: targetLabel(target))
                    }
                    .disabled(target.isInUse)
                }
            } label: {
                Label(simulatorStrings.chooseTarget, systemImage: "scope")
            }
            .disabled(!isAvailable || targets.isEmpty)
            if case .attached = session {
                Button(simulatorStrings.releaseInspector, action: release)
            }
        }

        if targets.isEmpty {
            Text(isAvailable ? simulatorStrings.noInspectorTargets : simulatorStrings.webInspectorUnavailable)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let target = attachedTarget {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: target.title.isEmpty ? target.url : target.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: target.url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(verbatim: target.bundleIdentifier ?? target.applicationName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attachedTarget: SimulatorWebInspectorTarget? {
        guard case let .attached(_, targetID) = session else { return nil }
        return targets.first(where: { $0.id == targetID })
    }

    private func targetLabel(_ target: SimulatorWebInspectorTarget) -> String {
        let page = target.title.isEmpty ? target.url : target.title
        let suffix = target.isInUse ? " · \(String(localized: simulatorStrings.inUse))" : ""
        return "\(target.applicationName) · \(page)\(suffix)"
    }
}
