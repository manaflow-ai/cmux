import CmuxNextDesign
import SwiftUI

/// Keycaps as the palette shows them.
struct KeycapsView: View {
    let keycaps: [String]

    var body: some View {
        HStack(spacing: Metrics.space1) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, key in
                Text(key).font(SettingsStyle.keycap).foregroundStyle(SettingsStyle.text)
                    .padding(.horizontal, Metrics.space2).frame(minWidth: Metrics.iconSize + Metrics.space2, minHeight: Metrics.iconSize + Metrics.space2)
                    .background(SettingsStyle.hover, in: RoundedRectangle(cornerRadius: Metrics.space2, style: .continuous))
            }
        }
    }
}
