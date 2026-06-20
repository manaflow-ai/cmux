#if canImport(AppKit)

public import SwiftUI

internal import AppKit
internal import Bonsplit
internal import CmuxFoundation

/// The "Tab Bar Backdrop Lab" panel: a grid of live `Bonsplit` tab bars, each
/// rendering a different split-button backdrop tuning over a transparent terminal
/// sample, with sliders for surface opacity, sample width, and candidate softness.
///
/// The panel is a faithful lift of the app-target lab. Its app-coupled source
/// values (the running terminal's default background color/opacity and the
/// production `Workspace` backdrop config) are injected as a
/// ``TabBarBackdropLabInputs`` snapshot, captured on the main actor when the app
/// builds the panel content, so the package holds no reference to `GhosttyApp` or
/// `Workspace`.
public struct TabBarBackdropLabView: View {
    private let inputs: TabBarBackdropLabInputs

    @State private var opacity: Double
    @State private var sidebarWidth: Double = 74
    @State private var sampleWidth: Double = 460
    @State private var candidateSoftness: Double

    /// Creates the lab panel from a snapshot of the live backdrop tuning.
    ///
    /// - Parameter inputs: The app-target backdrop reads the lab previews.
    public init(inputs: TabBarBackdropLabInputs) {
        self.inputs = inputs
        let currentOpacity = Double(WindowAppearanceSnapshot.clampedOpacity(inputs.defaultBackgroundOpacity))
        _opacity = State(initialValue: currentOpacity < 0.999 ? currentOpacity : 0.72)
        _candidateSoftness = State(initialValue: Double(inputs.productionBackdropSoftness))
    }

    private var terminalColor: NSColor {
        inputs.defaultBackgroundColor.usingColorSpace(.sRGB) ?? NSColor(hex: "#646461") ?? .windowBackgroundColor
    }

    private var surfaceColor: NSColor {
        terminalColor.withAlphaComponent(CGFloat(opacity))
    }

    private var separatorColor: NSColor {
        WindowChromeColorResolver().separatorColor(forChromeBackground: terminalColor)
    }

    private var candidateBackdropEffect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect {
        let softness = CGFloat(min(max(0, candidateSoftness), 1))
        let productionSoftness = inputs.productionBackdropSoftness
        let production = inputs.productionBackdropEffect
        func interpolate(strong: CGFloat, production: CGFloat, soft: CGFloat) -> CGFloat {
            if softness <= productionSoftness {
                let progress = softness / productionSoftness
                return strong + ((production - strong) * progress)
            }
            let progress = (softness - productionSoftness) / (1 - productionSoftness)
            return production + ((soft - production) * progress)
        }

        return .init(
            style: .translucentChrome,
            fadeWidth: interpolate(strong: 20, production: production.fadeWidth, soft: 240),
            contentFadeWidth: interpolate(strong: 0, production: production.contentFadeWidth, soft: 80),
            solidWidth: interpolate(strong: 72, production: production.solidWidth, soft: 0),
            solidSurfaceWidthAdjustment: production.solidSurfaceWidthAdjustment,
            fadeRampStartFraction: interpolate(strong: 0, production: production.fadeRampStartFraction, soft: 0.98),
            leadingOpacity: production.leadingOpacity,
            trailingOpacity: interpolate(strong: 1.0, production: production.trailingOpacity, soft: 0.25),
            contentOcclusionFraction: interpolate(strong: 0, production: production.contentOcclusionFraction, soft: 1),
            masksTabContent: true
        )
    }

    private var variants: [TabBarBackdropLabVariant] {
        let chromeHex = surfaceColor.hexString(includeAlpha: true)
        let paneHex = "#00000000"
        let borderHex = separatorColor.hexString(includeAlpha: true)
        let opacityValue = CGFloat(opacity)
        let candidate = candidateBackdropEffect

        return [
            variant(
                id: "candidate",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidate", defaultValue: "Candidate"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidate.detail", defaultValue: "Translucent chrome with tab occlusion."),
                effect: candidate,
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateWideFade",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateWideFade", defaultValue: "Wide fade"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateWideFade.detail", defaultValue: "Same model with a softer edge."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 104,
                    contentFadeWidth: 46,
                    solidWidth: 10,
                    fadeRampStartFraction: 0.88,
                    leadingOpacity: 0,
                    trailingOpacity: 1.0,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateSoftEnd",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateSoftEnd", defaultValue: "Soft end"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateSoftEnd.detail", defaultValue: "Same mask with lighter button fill."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 100,
                    contentFadeWidth: 42,
                    solidWidth: 14,
                    fadeRampStartFraction: 0.84,
                    leadingOpacity: 0,
                    trailingOpacity: 0.82,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateTightEdge",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateTightEdge", defaultValue: "Tight edge"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateTightEdge.detail", defaultValue: "More coverage at the fade start."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 90,
                    contentFadeWidth: 34,
                    solidWidth: 24,
                    fadeRampStartFraction: 0.70,
                    leadingOpacity: 0.08,
                    trailingOpacity: 1.0,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "candidateLowContrast",
                title: String(localized: "debug.tabBarBackdropLab.variant.candidateLowContrast", defaultValue: "Low contrast"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.candidateLowContrast.detail", defaultValue: "Lower-opacity solid region."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 102,
                    contentFadeWidth: 38,
                    solidWidth: 12,
                    fadeRampStartFraction: 0.86,
                    leadingOpacity: 0,
                    trailingOpacity: 0.72,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "translucentChrome",
                title: String(localized: "debug.tabBarBackdropLab.variant.translucentChrome", defaultValue: "6 Translucent chrome"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.translucentChrome.detail", defaultValue: "Shows the bleed-through problem."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 96,
                    contentFadeWidth: 42,
                    solidWidth: 18,
                    fadeRampStartFraction: 0.82,
                    leadingOpacity: 0,
                    trailingOpacity: 1.0,
                    masksTabContent: false
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "translucentNoFade",
                title: String(localized: "debug.tabBarBackdropLab.variant.translucentNoFade", defaultValue: "No fade"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.translucentNoFade.detail", defaultValue: "Hard translucent edge for contrast."),
                effect: .init(
                    style: .translucentChrome,
                    fadeWidth: 0,
                    solidWidth: 30,
                    leadingOpacity: 1.0,
                    trailingOpacity: 1.0,
                    masksTabContent: true
                ),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "hidden",
                title: String(localized: "debug.tabBarBackdropLab.variant.hidden", defaultValue: "7 No backdrop"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.hidden.detail", defaultValue: "Control sample. Tabs remain visible below the buttons."),
                effect: .init(style: .hidden, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "precompositedPane",
                title: String(localized: "debug.tabBarBackdropLab.variant.precompositedPane", defaultValue: "0 Opaque pane composite"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.precompositedPane.detail", defaultValue: "Old candidate. Covers too hard."),
                effect: .init(style: .precompositedPaneBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "opaquePane",
                title: String(localized: "debug.tabBarBackdropLab.variant.opaquePane", defaultValue: "1 Raw pane opaque"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.opaquePane.detail", defaultValue: "Forces the pane fill to full opacity."),
                effect: .init(style: .opaquePaneBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "opaqueBar",
                title: String(localized: "debug.tabBarBackdropLab.variant.opaqueBar", defaultValue: "2 Raw bar opaque"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.opaqueBar.detail", defaultValue: "Uses the tab chrome color at full opacity."),
                effect: .init(style: .opaqueBarBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "precompositedBar",
                title: String(localized: "debug.tabBarBackdropLab.variant.precompositedBar", defaultValue: "5 Opaque bar composite"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.precompositedBar.detail", defaultValue: "Composites tab chrome over the window background."),
                effect: .init(style: .precompositedBarBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "windowBackground",
                title: String(localized: "debug.tabBarBackdropLab.variant.windowBackground", defaultValue: "3 Window background"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.windowBackground.detail", defaultValue: "Uses AppKit windowBackgroundColor."),
                effect: .init(style: .windowBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
            variant(
                id: "controlBackground",
                title: String(localized: "debug.tabBarBackdropLab.variant.controlBackground", defaultValue: "4 Control background"),
                detail: String(localized: "debug.tabBarBackdropLab.variant.controlBackground.detail", defaultValue: "Uses AppKit controlBackgroundColor."),
                effect: .init(style: .controlBackground, fadeWidth: 24, leadingOpacity: 0, trailingOpacity: 1.0, masksTabContent: false),
                chromeHex: chromeHex,
                paneHex: paneHex,
                borderHex: borderHex,
                opacity: opacityValue
            ),
        ]
    }

    private var sampleWidthValue: CGFloat {
        CGFloat(sampleWidth)
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.fixed(sampleWidthValue), spacing: 16, alignment: .top),
            GridItem(.fixed(sampleWidthValue), spacing: 16, alignment: .top),
            GridItem(.fixed(sampleWidthValue), spacing: 16, alignment: .top),
        ]
    }

    private var gridContentWidth: CGFloat {
        sampleWidthValue * 3 + 32
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "debug.tabBarBackdropLab.title", defaultValue: "Tab Bar Backdrop Lab"))
                        .font(.headline)
                    Text(String(localized: "debug.tabBarBackdropLab.subtitle", defaultValue: "Live Bonsplit tab bars with overflow tabs under the split buttons. The window background is transparent."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 18) {
                    labSlider(
                        title: String(localized: "debug.tabBarBackdropLab.opacity", defaultValue: "Surface opacity"),
                        value: $opacity,
                        range: 0.2...1.0,
                        displayValue: "\(Int(opacity * 100))%",
                        width: 150
                    )
                    labSlider(
                        title: String(localized: "debug.tabBarBackdropLab.width", defaultValue: "Sample width"),
                        value: $sampleWidth,
                        range: 390...580,
                        displayValue: "\(Int(sampleWidth))",
                        width: 140
                    )
                    labSlider(
                        title: String(localized: "debug.tabBarBackdropLab.candidateSoftness", defaultValue: "Candidate softness"),
                        value: $candidateSoftness,
                        range: 0...1,
                        displayValue: "\(Int(candidateSoftness * 100))%",
                        width: 180
                    )
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            ScrollView {
                LazyVGrid(
                    columns: gridColumns,
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(variants) { variant in
                        TabBarBackdropLabSample(
                            variant: variant,
                            sidebarWidth: CGFloat(sidebarWidth),
                            tabBarHeight: inputs.tabBarHeight
                        )
                        .id(variant.renderIdentity)
                        .frame(width: sampleWidthValue, alignment: .topLeading)
                    }
                }
                .frame(minWidth: gridContentWidth, alignment: .leading)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.visible)
        }
        .padding(18)
        .background(Color.clear)
        .frame(minWidth: 1320, minHeight: 820)
    }

    private func variant(
        id: String,
        title: String,
        detail: String,
        effect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect,
        chromeHex: String,
        tabBarHex: String? = nil,
        splitButtonBackdropHex: String? = nil,
        paneHex: String,
        borderHex: String,
        opacity: CGFloat
    ) -> TabBarBackdropLabVariant {
        TabBarBackdropLabVariant(
            id: id,
            title: title,
            detail: detail,
            effect: effect,
            chromeHex: chromeHex,
            tabBarHex: tabBarHex ?? chromeHex,
            splitButtonBackdropHex: splitButtonBackdropHex ?? tabBarHex ?? chromeHex,
            paneHex: paneHex,
            borderHex: borderHex,
            terminalColor: terminalColor,
            surfaceColor: surfaceColor,
            separatorColor: separatorColor,
            opacity: opacity
        )
    }

    private func labSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String,
        width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) \(displayValue)")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
            Slider(value: value, in: range)
                .frame(width: width)
        }
    }
}

#endif
