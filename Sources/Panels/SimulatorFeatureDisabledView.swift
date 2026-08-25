import SwiftUI

struct SimulatorFeatureDisabledView: View {
    let panel: SimulatorPanel
    let appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "simulator.featureDisabled.title",
                defaultValue: "Simulator is temporarily unavailable"
            ))
            .font(.headline)
            Text(String(
                localized: "simulator.featureDisabled.message",
                defaultValue: "This feature has been disabled remotely."
            ))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(
            \.colorScheme,
            cmuxReadableColorScheme(for: appearance.backgroundColor)
        )
    }
}
