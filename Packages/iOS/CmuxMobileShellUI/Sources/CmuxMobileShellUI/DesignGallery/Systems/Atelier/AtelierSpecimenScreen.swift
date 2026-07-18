#if DEBUG
import SwiftUI

/// Collects Atelier's palette, typography, states, shapes, controls, and glass treatment.
struct AtelierSpecimenScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Atelier specimen")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.textPrimary)

                specimenSection(title: "Palette", theme: theme) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        AtelierPaletteSwatch(name: "bg0 · Paper", hex: schemeHex(light: "#F7F3EC", dark: "#201C18"), color: theme.background)
                        AtelierPaletteSwatch(name: "bg1 · Card", hex: schemeHex(light: "#FFFFFF", dark: "#2A251F"), color: theme.card)
                        AtelierPaletteSwatch(name: "bg2 · Inset", hex: schemeHex(light: "#EFE9DE", dark: "#363028"), color: theme.inset)
                        AtelierPaletteSwatch(name: "hairline", hex: schemeHex(light: "#2A2520 · 10%", dark: "#EDE7DE · 10%"), color: theme.hairline)
                        AtelierPaletteSwatch(name: "text.primary · Ink", hex: schemeHex(light: "#2A2520", dark: "#EDE7DE"), color: theme.textPrimary)
                        AtelierPaletteSwatch(name: "text.secondary", hex: schemeHex(light: "#6B6259", dark: "#B3A99C"), color: theme.textSecondary)
                        AtelierPaletteSwatch(name: "text.tertiary", hex: schemeHex(light: "#A39B8F", dark: "#7A7166"), color: theme.textTertiary)
                        AtelierPaletteSwatch(name: "accent · Terracotta", hex: schemeHex(light: "#C15F3C", dark: "#D97757"), color: theme.accent)
                        AtelierPaletteSwatch(name: "needsYou · Ochre", hex: schemeHex(light: "#B07818", dark: "#D9A03F"), color: theme.needsYou)
                        AtelierPaletteSwatch(name: "running · Slate", hex: schemeHex(light: "#5F7484", dark: "#8FA5B5"), color: theme.running)
                        AtelierPaletteSwatch(name: "done · Sage", hex: schemeHex(light: "#5F7D58", dark: "#8CAB84"), color: theme.done)
                        AtelierPaletteSwatch(name: "failed · Brick", hex: schemeHex(light: "#A84632", dark: "#CC6B55"), color: theme.failed)
                        AtelierPaletteSwatch(name: "idle", hex: schemeHex(light: "#A39B8F", dark: "#7A7166"), color: theme.idle)
                    }
                }

                specimenSection(title: "Type", theme: theme) {
                    VStack(alignment: .leading, spacing: 18) {
                        typeSample("Screen title · 28 semibold serif", size: 28, weight: .semibold, design: .serif, theme: theme)
                        typeSample("Card title · 19 semibold serif", size: 19, weight: .semibold, design: .serif, theme: theme)
                        typeSample("Body · 16 regular", size: 16, weight: .regular, design: .default, theme: theme)
                        typeSample("Caption · 13 regular", size: 13, weight: .regular, design: .default, theme: theme)
                        typeSample("Mono block · 12 regular", size: 12, weight: .regular, design: .monospaced, theme: theme)
                    }
                }

                specimenSection(title: "States", theme: theme) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(GalleryAgentState.allCases.enumerated()), id: \.offset) { _, state in
                            AtelierStatusMark(state: state)
                        }
                    }
                }

                specimenSection(title: "Components", theme: theme) {
                    VStack(spacing: 16) {
                        HStack(spacing: 12) {
                            Button(action: {}) {
                                Text(DesignGalleryFixtures.approvalActions[0])
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(theme.accentForeground)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(AtelierPressButtonStyle())

                            Button(action: {}) {
                                Text("Not yet")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(theme.textPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(AtelierPressButtonStyle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Warm card")
                                .font(.system(size: 19, weight: .semibold, design: .serif))
                                .foregroundStyle(theme.textPrimary)
                            Text("One calm surface, one clear next action.")
                                .font(.system(size: 16))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(theme.hairline, lineWidth: 1)
                        }
                        .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 2)

                        AtelierComposer(placeholder: "Send a message…")
                            .padding(.horizontal, -20)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func specimenSection<Content: View>(
        title: String,
        theme: AtelierTheme,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(theme.textPrimary)
            content()
        }
    }

    @ViewBuilder
    private func typeSample(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design,
        theme: AtelierTheme
    ) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: design))
            .foregroundStyle(theme.textPrimary)
            .minimumScaleFactor(0.7)
    }

    private func schemeHex(light: String, dark: String) -> String {
        colorScheme == .dark ? dark : light
    }
}
#endif
