#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings → Appearance → Accent color, as in the ChatGPT iOS app: one row per
/// accent with its swatch and a checkmark on the chosen one. Every chrome tint
/// (Send, armed keys, the diff's match bar, Unlock, the context ring) reads the
/// choice; Default keeps the monochrome look. The names match the desktop's
/// `appearance.accent` values.
struct AccentColorPage: View {
    let accents: CmuxMobileAccentTheme

    var body: some View {
        List {
            Section {
                ForEach(CmuxMobileAccent.allCases) { accent in
                    AccentRow(accent: accent, selected: accent == accents.accent) {
                        accents.accent = accent
                    }
                }
            } footer: {
                Text("Colors Send, armed keys, the Unlock button and other highlights.")
            }
        }
        .settingsPage("Accent color")
    }
}

private struct AccentRow: View {
    let accent: CmuxMobileAccent
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button {
            choose()
            theme.haptics.selection()
        } label: {
            HStack(spacing: CmuxMobileListColumn.groupedGap) {
                AccentSwatch(accent: accent)
                Text(verbatim: accent.title)
                    .font(theme.type.rowTitle)
                    .foregroundStyle(theme.colors.label)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.colors.label)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.accentColor.\(accent.rawValue)")
    }
}

/// The accent's fill in a circle on the icon column, with a hairline so
/// Default's white (dark) or black (light) still reads as a swatch.
private struct AccentSwatch: View {
    let accent: CmuxMobileAccent
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        Circle()
            .fill(accent.accent)
            .overlay { Circle().strokeBorder(theme.colors.separator, lineWidth: 0.5) }
            .frame(width: min(size, 40), height: min(size, 40))
            .frame(width: CmuxMobileListColumn.grouped(typeSize).mark)
            .accessibilityHidden(true)
    }
}
#endif
