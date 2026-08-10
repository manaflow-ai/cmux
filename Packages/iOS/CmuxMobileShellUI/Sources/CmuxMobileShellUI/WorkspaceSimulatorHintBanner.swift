#if os(iOS)
import SwiftUI

/// One-time dismissable banner teaching that this workspace has a Mac
/// Simulator pane the phone can stream, and where to open it. Tapping the
/// body opens the simulator directly; the copy also names the surfaces menu
/// so the user learns the durable path.
struct WorkspaceSimulatorHintBanner: View {
    let openSimulator: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: openSimulator) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(
                            localized: "workspace.simulator.hint.title",
                            defaultValue: "This workspace has a Mac Simulator",
                            bundle: .module
                        ))
                        .font(.subheadline.weight(.semibold))
                        Text(String(
                            localized: "workspace.simulator.hint.body",
                            defaultValue: "Tap to stream and control it from this phone. It also lives in the Terminals menu in the toolbar.",
                            bundle: .module
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .padding(5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "workspace.simulator.hint.dismiss",
                defaultValue: "Dismiss",
                bundle: .module
            ))
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("MobileSimulatorHint")
    }
}
#endif
