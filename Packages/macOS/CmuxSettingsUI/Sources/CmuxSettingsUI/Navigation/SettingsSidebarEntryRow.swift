import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Sidebar row used inside the settings window's `List`.
///
/// Mirrors the legacy in-app `SettingsSidebarEntryRow`: 16pt SF
/// Symbol icon left-aligned in a fixed-width slot, then a left-stacked
/// title with an optional subtitle in caption / secondary style. Both
/// lines are single-line-clipped so long entries get truncated rather
/// than wrap and inflate row height.
@MainActor
struct SettingsSidebarEntryRow: View {
    let title: String
    let symbolName: String
    let subtitle: String?
    let isSelected: Bool
    @Environment(\.chromePalette) private var chromePalette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle((isSelected ? chromePalette.textOnSelected : chromePalette.textSecondary).swiftUIColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle((isSelected ? chromePalette.textOnSelected : chromePalette.textPrimary).swiftUIColor)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .cmuxFont(.caption)
                        .foregroundStyle((isSelected ? chromePalette.textOnSelected : chromePalette.textSecondary).swiftUIColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(isSelected ? chromePalette.surfaceSelected.swiftUIColor : Color.clear)
    }
}
