import CmuxMobileShellModel
import SwiftUI

/// Compact workspace-row signifier that the workspace has a Mac Simulator
/// pane the phone can stream. A green dot marks a booted device (live
/// content right now). Passive label by design: tapping the row opens the
/// workspace, where the simulator hint banner and the surface picker take
/// over — the chip only makes the feature visible from the list.
struct WorkspaceSimulatorChipLabel: View {
    let workspace: MobileWorkspacePreview

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone")
                .font(.caption2.weight(.semibold))
            if workspace.hasBootedSimulator {
                Circle()
                    .fill(.green)
                    .frame(width: 5, height: 5)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            workspace.hasBootedSimulator
                ? String(
                    localized: "workspace.simulator.chip.accessibility.booted",
                    defaultValue: "Simulator running",
                    bundle: .module
                )
                : String(
                    localized: "workspace.simulator.chip.accessibility",
                    defaultValue: "Simulator attached",
                    bundle: .module
                )
        )
        .accessibilityIdentifier("MobileSimulatorChip-\(workspace.rpcWorkspaceID.rawValue)")
    }
}
