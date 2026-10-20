import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Visual three-up App Icon picker row.
///
/// Mirrors the legacy in-app `AppIconPickerRow`: a leading title +
/// subtitle and a trailing row of three tappable icon tiles
/// (Automatic / Light / Dark). The Automatic tile shows the two
/// concrete icons overlapping; the others show the real raster icon
/// from the host app's asset catalog.
///
/// The icon images live in the host app target (not the package), so
/// they're resolved through `Bundle.main` via the asset name.
@MainActor
struct AppIconPickerRow: View {
    let selectedMode: AppIconMode
    let onSelect: (AppIconMode) -> Void

    private let iconSize: CGFloat = 48
    private let autoIconSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.app.appIcon", defaultValue: "App Icon"))
                    .cmuxFont(size: 13, weight: .medium)
                Text(String(localized: "settings.app.appIcon.subtitle", defaultValue: "Dock and app switcher"))
                    .cmuxFont(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AppIconMode.allCases, id: \.self) { mode in
                    let isSelected = selectedMode == mode
                    Button {
                        onSelect(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if mode == .automatic {
                                    ZStack {
                                        Image("AppIconLight", bundle: .main)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: autoIconSize, height: autoIconSize)
                                            .clipShape(RoundedRectangle(cornerRadius: autoIconSize * 0.22, style: .continuous))
                                            .offset(x: -10)
                                        Image("AppIconDark", bundle: .main)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: autoIconSize, height: autoIconSize)
                                            .clipShape(RoundedRectangle(cornerRadius: autoIconSize * 0.22, style: .continuous))
                                            .offset(x: 10)
                                    }
                                    .frame(width: iconSize, height: iconSize)
                                } else {
                                    Image(iconAssetName(for: mode), bundle: .main)
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: iconSize, height: iconSize)
                                        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                                }
                            }

                            Text(iconDisplayName(mode))
                                .cmuxFont(size: 10)
                                .foregroundColor(isSelected ? .primary : .secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconAssetName(for mode: AppIconMode) -> String {
        switch mode {
        case .automatic: return "AppIconLight"
        case .light: return "AppIconLight"
        case .dark: return "AppIconDark"
        }
    }

    private func iconDisplayName(_ mode: AppIconMode) -> String {
        switch mode {
        case .automatic: return String(localized: "appIcon.automatic", defaultValue: "Automatic")
        case .light: return String(localized: "appIcon.light", defaultValue: "Light")
        case .dark: return String(localized: "appIcon.dark", defaultValue: "Dark")
        }
    }
}
