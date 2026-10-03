import CmuxNextDesign
import SwiftUI

/// Museum attribution reachable beside the Appearance theme controls.
struct BackdropArtAttributionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text(SettingsWindowStrings.backdropArtCredit)
                .font(SettingsStyle.caption)
                .foregroundStyle(SettingsStyle.secondary)
            Link(SettingsWindowStrings.backdropArtSource, destination: BackdropArt.wheatField.sourceURL)
                .font(SettingsStyle.caption)
        }
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space2)
    }
}
