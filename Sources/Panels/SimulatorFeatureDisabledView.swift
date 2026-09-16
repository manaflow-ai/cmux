import SwiftUI

struct SimulatorFeatureDisabledView: View {
    let panel: SimulatorPanel
    let appearance: PanelAppearance

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(String(
                    localized: "simulator.featureDisabled.title",
                    defaultValue: "Simulator is temporarily unavailable"
                ))
            } icon: {
                Image(systemName: "iphone.slash")
            }
        } description: {
            Text(String(
                localized: "simulator.featureDisabled.message",
                defaultValue: "This feature has been disabled remotely."
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(
            \.colorScheme,
            cmuxReadableColorScheme(for: appearance.backgroundColor)
        )
    }
}
