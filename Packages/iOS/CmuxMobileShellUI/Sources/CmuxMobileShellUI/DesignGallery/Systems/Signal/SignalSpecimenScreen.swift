#if DEBUG
import SwiftUI

/// Catalogs Signal's palette, type roles, statuses, and core components.
struct SignalSpecimenScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SignalTheme(scheme: colorScheme)
        let statuses = [
            GalleryAgentState.needsYou,
            GalleryAgentState.failed,
            GalleryAgentState.running,
            GalleryAgentState.done,
            GalleryAgentState.idle,
        ]
        let palette: [(String, String, Color, CGFloat)] = colorScheme == .dark ? [
            ("BG0", "#121212", theme.bg0, 24),
            ("SURFACE", "#1C1C1A", theme.surface, 24),
            ("INK", "#F2F2F0", theme.ink, 24),
            ("TEXT.SECONDARY", "#A3A39E", theme.secondaryText, 24),
            ("HAIRLINE", "#F2F2F0 · 14%", theme.hairline, 24),
            ("SIGNAL.NEEDSYOU", "#F0B429", theme.needsYou, 6),
            ("SIGNAL.RUNNING", "#4A9EFF", theme.running, 6),
            ("SIGNAL.DONE", "#34C471", theme.done, 6),
            ("SIGNAL.FAILED", "#F0554A", theme.failed, 6),
            ("SIGNAL.IDLE", "#6E6E69", theme.idle, 6),
        ] : [
            ("BG0", "#F5F5F4", theme.bg0, 24),
            ("SURFACE", "#FFFFFF", theme.surface, 24),
            ("INK", "#111111", theme.ink, 24),
            ("TEXT.SECONDARY", "#555550", theme.secondaryText, 24),
            ("HAIRLINE", "#111111 · 12%", theme.hairline, 24),
            ("SIGNAL.NEEDSYOU", "#E8A200", theme.needsYou, 6),
            ("SIGNAL.RUNNING", "#0A7AFF", theme.running, 6),
            ("SIGNAL.DONE", "#1F9E55", theme.done, 6),
            ("SIGNAL.FAILED", "#D93025", theme.failed, 6),
            ("SIGNAL.IDLE", "#8A8A85", theme.idle, 6),
        ]

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Specimen")
                    .font(.system(.title, design: .default, weight: .heavy))
                    .foregroundStyle(theme.ink)

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Palette", color: theme.secondaryText)
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 4
                    ) {
                        ForEach(Array(palette.enumerated()), id: \.offset) { _, token in
                            SignalPaletteSwatch(
                                name: token.0,
                                hex: token.1,
                                color: token.2,
                                markSize: token.3,
                                theme: theme
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SignalSectionLabel(text: "Type Scale", color: theme.secondaryText)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SCREEN TITLE · 28 HEAVY")
                            .font(.system(.caption2, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                        Text("Fleet status")
                            .font(.system(.title, design: .default, weight: .heavy))
                            .foregroundStyle(theme.ink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SECTION LABEL · 11 SEMIBOLD")
                            .font(.system(.caption2, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                        SignalSectionLabel(text: "Needs You", color: theme.ink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("BODY · 15 REGULAR")
                            .font(.system(.caption2, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                        Text("Every pixel informs or is deleted.")
                            .font(.system(.subheadline, design: .default, weight: .regular))
                            .foregroundStyle(theme.ink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("DATA · SF MONO 13")
                            .font(.system(.caption2, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                        Text("14:32  ·  feat-ios-design-gallery  ·  2m")
                            .font(.system(.footnote, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.ink)
                            .minimumScaleFactor(0.7)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("TERMINAL · SF MONO 12")
                            .font(.system(.caption2, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                        Text("$ ./scripts/reload.sh --tag dsgal")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(theme.ink)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SignalSectionLabel(text: "Five Status Encodings", color: theme.secondaryText)
                    VStack(spacing: 0) {
                        ForEach(Array(statuses.enumerated()), id: \.offset) { _, state in
                            SignalStatusMeaningRow(
                                style: SignalStatusStyle(state: state, theme: theme),
                                theme: theme
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SignalSectionLabel(text: "Core Components", color: theme.secondaryText)

                    SignalWorkspaceRow(
                        workspace: DesignGalleryFixtures.workspaces[1],
                        theme: theme
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.hairline)
                            .frame(height: 1)
                    }

                    SignalActionButtons(theme: theme)
                    SignalTriageBar(theme: theme)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
    }
}
#endif
