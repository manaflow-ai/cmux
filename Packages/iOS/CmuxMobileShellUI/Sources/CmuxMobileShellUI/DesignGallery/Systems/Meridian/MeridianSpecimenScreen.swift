#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Collects Meridian's palette, type ramp, statuses, and core glass components.
struct MeridianSpecimenScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Meridian")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(theme.label)

                specimenSection(title: "Palette") {
                    LazyVGrid(columns: paletteColumns, alignment: .leading, spacing: 12) {
                        MeridianPaletteSwatch(name: "systemBackground", hex: theme.backgroundHex, color: theme.background)
                        MeridianPaletteSwatch(name: "secondarySystemBackground", hex: theme.secondaryBackgroundHex, color: theme.secondaryBackground)
                        MeridianPaletteSwatch(name: "tertiarySystemFill", hex: theme.tertiaryFillHex, color: theme.tertiaryFill)
                        MeridianPaletteSwatch(name: "label", hex: theme.labelHex, color: theme.label)
                        MeridianPaletteSwatch(name: "secondaryLabel", hex: theme.secondaryLabelHex, color: theme.secondaryLabel)
                        MeridianPaletteSwatch(name: "tertiaryLabel", hex: theme.tertiaryLabelHex, color: theme.tertiaryLabel)
                        MeridianPaletteSwatch(name: "accent", hex: theme.accentHex, color: theme.accent)
                        MeridianPaletteSwatch(name: "needsYou", hex: theme.needsYouHex, color: theme.needsYou)
                        MeridianPaletteSwatch(name: "running", hex: theme.accentHex, color: theme.running)
                        MeridianPaletteSwatch(name: "done", hex: theme.doneHex, color: theme.done)
                        MeridianPaletteSwatch(name: "failed", hex: theme.failedHex, color: theme.failed)
                        MeridianPaletteSwatch(name: "idle", hex: theme.tertiaryLabelHex, color: theme.idle)
                    }
                }

                specimenSection(title: "Light & dark") {
                    VStack(spacing: 12) {
                        MeridianSchemePreview(title: "Light")
                            .environment(\.colorScheme, .light)
                        MeridianSchemePreview(title: "Dark")
                            .environment(\.colorScheme, .dark)
                    }
                }

                specimenSection(title: "Dynamic Type") {
                    VStack(alignment: .leading, spacing: 16) {
                        MeridianTypeSample(role: "Large Title", sample: "Content first", font: .largeTitle)
                        MeridianTypeSample(role: "Headline", sample: "Workspace status", font: .headline)
                        MeridianTypeSample(role: "Body", sample: "Agent response and settings copy", font: .body)
                        MeridianTypeSample(role: "Subheadline", sample: "Supporting information", font: .subheadline)
                        MeridianTypeSample(role: "Caption", sample: "14:32 · two minutes ago", font: .caption)
                        MeridianTypeSample(role: "Mono branch", sample: "feat-ios-design-gallery", font: .subheadline.monospaced())
                    }
                }

                specimenSection(title: "Status vocabulary") {
                    VStack(spacing: 12) {
                        statusRow(.needsYou)
                        statusRow(.failed)
                        statusRow(.running)
                        statusRow(.done)
                        statusRow(.idle)
                    }
                }

                specimenSection(title: "Glass chrome") {
                    VStack(spacing: 16) {
                        HStack(spacing: 12) {
                            glassCircle(symbol: "keyboard", label: "Keyboard")
                            glassCircle(symbol: "ellipsis", label: "More")
                            Button(DesignGalleryFixtures.approvalActions[0]) {}
                                .mobileGlassProminentButton()
                                .tint(theme.accent)
                                .frame(minHeight: 44)
                        }

                        MeridianComposer()

                        VStack(spacing: 8) {
                            Capsule()
                                .fill(theme.tertiaryLabel)
                                .frame(width: 36, height: 5)
                            Text("Sheet grabber region")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryLabel)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .mobileGlassField(cornerRadius: theme.cardRadius)

                        MeridianFloatingTabBar(selectedPage: .hub)
                    }
                }
            }
            .padding(.horizontal, theme.horizontalInset)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .background(theme.background.ignoresSafeArea())
        .tint(theme.accent)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private var paletteColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    private func specimenSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.label)
            content()
        }
        .padding(16)
        .background(
            theme.secondaryBackground,
            in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        )
    }

    private func statusRow(_ state: GalleryAgentState) -> some View {
        HStack(spacing: 12) {
            MeridianStatusSymbol(state: state, font: .headline)
                .frame(width: 30, height: 30)
            Text(theme.label(for: state))
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.label)
            Spacer()
            Text(theme.symbolName(for: state))
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minHeight: 44)
    }

    private func glassCircle(symbol: String, label: String) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(theme.label)
                .frame(width: 48, height: 48)
                .mobileGlassCircle()
        }
        .buttonStyle(MeridianPressButtonStyle())
        .accessibilityLabel(label)
    }
}
#endif
