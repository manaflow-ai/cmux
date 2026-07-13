#if DEBUG
import SwiftUI

/// Displays Phosphor's complete palette, type scale, states, and core controls.
struct PhosphorSpecimenScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sectionTitle("PALETTE", theme: theme)
                paletteGrid(theme: theme)

                sectionTitle("TYPE SCALE", theme: theme)
                typeScale(theme: theme)

                sectionTitle("STATUS ENCODING", theme: theme)
                statusGrid(theme: theme)

                sectionTitle("CORE COMPONENTS", theme: theme)
                componentRail(theme: theme)
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg0.ignoresSafeArea())
    }

    private func sectionTitle(_ text: String, theme: PhosphorTheme) -> some View {
        Text(text)
            .font(typography.caption)
            .tracking(0.8)
            .foregroundStyle(theme.textTertiary)
    }

    private func paletteGrid(theme: PhosphorTheme) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            ForEach(Array(palette(theme: theme).enumerated()), id: \.offset) { _, swatch in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(swatch.2)
                        .frame(width: 36, height: 36)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(theme.hairline, lineWidth: 1)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(swatch.0)
                            .font(typography.captionSemibold)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(swatch.1)
                            .font(typography.monoCaption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func typeScale(theme: PhosphorTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            typeRow("Title · SF Pro 17 Semibold", sample: "Agent status", font: typography.title, theme: theme)
            typeRow("Body · SF Pro 15 Regular", sample: "Terminal is the hero.", font: typography.body, theme: theme)
            typeRow("Caption · SF Pro 12 Regular", sample: "UPDATED 2 MINUTES AGO", font: typography.caption, theme: theme)
            typeRow("Data · SF Mono 13", sample: "feat-ios-design-gallery · 14:32", font: typography.data, theme: theme)
            typeRow("Terminal · SF Mono 12 / 1.3", sample: "$ ./scripts/reload.sh --tag dsgal", font: typography.terminal, theme: theme)
        }
        .padding(12)
        .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func typeRow(
        _ role: String,
        sample: String,
        font: Font,
        theme: PhosphorTheme
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role)
                .font(typography.monoCaption)
                .foregroundStyle(theme.textTertiary)
            Text(sample)
                .font(font)
                .foregroundStyle(theme.textPrimary)
        }
    }

    private func statusGrid(theme: PhosphorTheme) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Array(specimenStates.enumerated()), id: \.offset) { index, state in
                HStack(spacing: 8) {
                    PhosphorStatusDot(state: state)
                    PhosphorStatusChip(state: state)
                    Spacer(minLength: 0)
                    Text(["2m", "3h", "12m", "1h", "2d"][index])
                        .font(typography.data)
                        .monospacedDigit()
                        .foregroundStyle(theme.statusColor(state))
                }
                .padding(8)
                .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func componentRail(theme: PhosphorTheme) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("COMMAND BAR")
                        .font(typography.monoCaption)
                        .foregroundStyle(theme.textTertiary)
                    PhosphorCommandBar(showsApprove: true)
                }
                .padding(12)
                .frame(width: 320, alignment: .leading)
                .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("TOOL CARD")
                        .font(typography.monoCaption)
                        .foregroundStyle(theme.textTertiary)
                    PhosphorToolCard(
                        title: DesignGalleryFixtures.chatEntries[2].text,
                        command: DesignGalleryFixtures.chatEntries[2].toolCommand ?? "",
                        output: DesignGalleryFixtures.chatEntries[2].toolOutput ?? "",
                        timeText: DesignGalleryFixtures.chatEntries[2].timeText
                    )
                }
                .padding(12)
                .frame(width: 320, alignment: .leading)
                .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("BUTTONS")
                        .font(typography.monoCaption)
                        .foregroundStyle(theme.textTertiary)
                    HStack(spacing: 8) {
                        Button("Secondary", action: {})
                            .font(typography.bodySemibold)
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(theme.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .buttonStyle(PhosphorPressButtonStyle())
                        Button("Primary", action: {})
                            .font(typography.bodySemibold)
                            .foregroundStyle(theme.isDark ? theme.textPrimary : theme.bg1)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .buttonStyle(PhosphorPressButtonStyle())
                    }
                }
                .padding(12)
                .frame(width: 280, alignment: .leading)
                .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .scrollIndicators(.hidden)
    }

    private func palette(theme: PhosphorTheme) -> [(String, String, Color)] {
        let dark = theme.isDark
        return [
            ("bg0", dark ? "#0A0B0D" : "#F2F3F5", theme.bg0),
            ("bg1", dark ? "#111318" : "#FFFFFF", theme.bg1),
            ("bg2", dark ? "#1A1D24" : "#E9EBEE", theme.bg2),
            ("hairline", dark ? "#FFFFFF · 8%" : "#000000 · 10%", theme.hairline),
            ("text.primary", dark ? "#E8EAED" : "#1A1D24", theme.textPrimary),
            ("text.secondary", dark ? "#9BA1AC" : "#5C6370", theme.textSecondary),
            ("text.tertiary", dark ? "#5C6370" : "#9BA1AC", theme.textTertiary),
            ("accent", dark ? "#4D9DFF" : "#1D6FE0", theme.accent),
            ("status.needsYou", dark ? "#FFB224" : "#B87700", theme.statusNeedsYou),
            ("status.running", dark ? "#4D9DFF" : "#1D6FE0", theme.statusRunning),
            ("status.done", dark ? "#3DD68C" : "#17804F", theme.statusDone),
            ("status.failed", dark ? "#FF5D5D" : "#C93030", theme.statusFailed),
            ("status.idle", dark ? "#5C6370" : "#9BA1AC", theme.statusIdle),
        ]
    }

    private var specimenStates: [GalleryAgentState] {
        [.needsYou, .failed, .running, .done, .idle]
    }
}
#endif
