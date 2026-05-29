import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct AppIconPickerRow: View {
    let configurationReview: SettingsConfigurationReview
    let selectedMode: String
    let onSelect: (AppIconMode) -> Void

    private let iconSize: CGFloat = 48
    private let autoIconSize: CGFloat = 36

    init(
        configurationReview: SettingsConfigurationReview,
        selectedMode: String,
        onSelect: @escaping (AppIconMode) -> Void
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.selectedMode = selectedMode
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.app.appIcon", defaultValue: "App Icon"))
                    .font(.system(size: 13, weight: .medium))
                Text(String(localized: "settings.app.appIcon.subtitle", defaultValue: "Dock and app switcher"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AppIconMode.allCases) { mode in
                    let isSelected = selectedMode == mode.rawValue
                    Button {
                        onSelect(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if mode == .automatic {
                                    ZStack {
                                        Image("AppIconLight")
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: autoIconSize, height: autoIconSize)
                                            .clipShape(RoundedRectangle(cornerRadius: autoIconSize * 0.22, style: .continuous))
                                            .offset(x: -10)
                                        Image("AppIconDark")
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: autoIconSize, height: autoIconSize)
                                            .clipShape(RoundedRectangle(cornerRadius: autoIconSize * 0.22, style: .continuous))
                                            .offset(x: 10)
                                    }
                                    .frame(width: iconSize, height: iconSize)
                                } else {
                                    Image(mode.imageName ?? "AppIconLight")
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: iconSize, height: iconSize)
                                        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                                }
                            }

                            Text(mode.displayName)
                                .font(.system(size: 10))
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
        .settingsSearchAnchors(configurationReview.searchAnchorIDs)
    }
}
