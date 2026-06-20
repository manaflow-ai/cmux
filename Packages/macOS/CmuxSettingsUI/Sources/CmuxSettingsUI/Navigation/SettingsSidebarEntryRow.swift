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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
