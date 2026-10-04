import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// Rooms or machines, from the App's live stores.
struct ListSectionCard: View {
    let rows: [SettingsListRow]?
    let empty: String
    let unavailable: String

    var body: some View {
        SettingsCard(title: nil) {
            if let rows {
                if rows.isEmpty {
                    Text(empty).foregroundStyle(SettingsStyle.secondary)
                        .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
                        .padding(.horizontal, Metrics.space5)
                }
                ForEach(rows) { row in
                    HStack(spacing: Metrics.space4) {
                        SettingsIconGlyph(icon: row.icon)
                            .frame(width: Metrics.iconSize + Metrics.space2)
                        Text(row.title)
                        if let subtitle = row.subtitle {
                            Text(subtitle).foregroundStyle(SettingsStyle.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if row.isActive {
                            Circle().fill(SettingsStyle.secondary).frame(width: Metrics.space3, height: Metrics.space3)
                        }
                    }
                    .padding(.horizontal, Metrics.space5)
                    .frame(minHeight: SettingsStyle.rowHeight)
                }
            } else {
                Text(unavailable).foregroundStyle(SettingsStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
                    .padding(.horizontal, Metrics.space5)
            }
        }
    }
}

/// An icon value in a Settings row: an emoji as text, anything else as an SF
/// Symbol (assets show a placeholder symbol until Settings draws assets).
struct SettingsIconGlyph: View {
    let icon: IconValue

    var body: some View {
        switch icon {
        case .emoji(let text): Text(text)
        case .symbol(let name): Image(systemName: name).foregroundStyle(SettingsStyle.secondary)
        case .image, .svg: Image(systemName: "photo").foregroundStyle(SettingsStyle.secondary)
        }
    }
}
