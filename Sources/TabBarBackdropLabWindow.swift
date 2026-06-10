import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Tab Bar Backdrop Lab Window
final class TabBarBackdropLabWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TabBarBackdropLabWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1040),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.tabBarBackdropLab.title", defaultValue: "Tab Bar Backdrop Lab")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .floating
        window.identifier = NSUserInterfaceItemIdentifier("cmux.tabBarBackdropLab")
        window.center()

        let hostingView = NSHostingView(rootView: TabBarBackdropLabView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

private struct TabBarBackdropLabView: View {
    @State private var opacity: Double
    @State private var sidebarWidth: Double = 74
    @State private var sampleWidth: Double = 460
    @State private var candidateSoftness: Double = Double(Workspace.bonsplitSplitButtonBackdropSoftness)

    init() {
        let currentOpacity = Double(WindowAppearanceSnapshot.clampedOpacity(GhosttyApp.shared.defaultBackgroundOpacity))
        _opacity = State(initialValue: currentOpacity < 0.999 ? currentOpacity : 0.72)
    }

    private var terminalColor: NSColor {
        GhosttyApp.shared.defaultBackgroundColor.usingColorSpace(.sRGB) ?? NSColor(hex: "#646461") ?? .windowBackgroundColor
    }

    private var surfaceColor: NSColor {
        terminalColor.withAlphaComponent(CGFloat(opacity))
    }

    private var separatorColor: NSColor {
        WindowChromeSeparatorColor.color(forChromeBackground: terminalColor)
    }

    private var candidateBackdropEffect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect {
        let softness = CGFloat(min(max(0, candidateSoftness), 1))
        let productionSoftness = Workspace.bonsplitSplitButtonBackdropSoftness
        let production = Workspace.bonsplitSplitButtonBackdropEffect()
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

    var body: some View {
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
                            sidebarWidth: CGFloat(sidebarWidth)
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

private struct TabBarBackdropLabSample: View {
    let variant: TabBarBackdropLabVariant
    let sidebarWidth: CGFloat
    @State private var controller: BonsplitController

    init(variant: TabBarBackdropLabVariant, sidebarWidth: CGFloat) {
        self.variant = variant
        self.sidebarWidth = sidebarWidth
        _controller = State(initialValue: Self.makeController(for: variant))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(variant.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(variant.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                TabBarBackdropLabSidebar(
                    title: String(localized: "debug.tabBarBackdropLab.leftSidebar", defaultValue: "L"),
                    surfaceColor: variant.surfaceColor,
                    separatorColor: variant.separatorColor,
                    trailingBorder: true
                )
                .frame(width: sidebarWidth)

                VStack(spacing: 0) {
                    TabBarBackdropLabTitlebar(
                        variant: variant,
                        title: String(localized: "debug.tabBarBackdropLab.titlebarSample", defaultValue: "workspace@lab:~")
                    )
                    .frame(height: 24)

                    BonsplitView(controller: controller) { tab, _ in
                        TabBarBackdropLabTerminalPane(
                            title: tab.title,
                            color: variant.terminalColor,
                            opacity: variant.opacity
                        )
                    } emptyPane: { _ in
                        Color.clear
                    }
                }
                .frame(height: 132)

                TabBarBackdropLabSidebar(
                    title: String(localized: "debug.tabBarBackdropLab.rightSidebar", defaultValue: "R"),
                    surfaceColor: variant.surfaceColor,
                    separatorColor: variant.separatorColor,
                    trailingBorder: false
                )
                .frame(width: sidebarWidth)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(nsColor: variant.separatorColor), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            applyVariant()
        }
        .onChange(of: variant.renderIdentity) { _, _ in
            applyVariant()
        }
    }

    private func applyVariant() {
        controller.configuration = Self.makeConfiguration(for: variant)
    }

    private static func makeAppearance(for variant: TabBarBackdropLabVariant) -> BonsplitConfiguration.Appearance {
        BonsplitConfiguration.Appearance(
            tabBarHeight: WindowChromeMetrics.bonsplitTabBarHeight,
            tabMinWidth: 138,
            tabMaxWidth: 210,
            tabTitleFontSize: 11,
            tabSpacing: 0,
            minimumPaneWidth: 120,
            minimumPaneHeight: 80,
            showSplitButtons: true,
            splitButtons: BonsplitConfiguration.SplitActionButton.defaults,
            splitButtonsOnHover: false,
            splitButtonBackdropEffect: variant.effect,
            animationDuration: 0.0,
            enableAnimations: false,
            chromeColors: .init(
                backgroundHex: variant.chromeHex,
                tabBarBackgroundHex: variant.tabBarHex,
                splitButtonBackdropHex: variant.splitButtonBackdropHex,
                paneBackgroundHex: variant.paneHex,
                borderHex: variant.borderHex
            )
        )
    }

    private static func makeConfiguration(for variant: TabBarBackdropLabVariant) -> BonsplitConfiguration {
        BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowTabReordering: false,
            allowCrossPaneTabMove: false,
            autoCloseEmptyPanes: false,
            contentViewLifecycle: .recreateOnSwitch,
            newTabPosition: .end,
            appearance: makeAppearance(for: variant)
        )
    }

    private static func makeController(for variant: TabBarBackdropLabVariant) -> BonsplitController {
        let controller = BonsplitController(configuration: makeConfiguration(for: variant))

        let titles = [
            String(localized: "debug.tabBarBackdropLab.tab.agentBrowserLogs", defaultValue: "agent-browser logs"),
            String(localized: "debug.tabBarBackdropLab.tab.terminalTransparency", defaultValue: "cmux terminal transparency"),
            String(localized: "debug.tabBarBackdropLab.tab.underlayText", defaultValue: "underlay tab text visible here"),
            String(localized: "debug.tabBarBackdropLab.tab.backdropCheck", defaultValue: "split button backdrop check"),
            String(localized: "debug.tabBarBackdropLab.tab.rightEdgeOverflow", defaultValue: "right edge overflow sample"),
            String(localized: "debug.tabBarBackdropLab.tab.hiddenBelowControls", defaultValue: "tabs hidden below controls")
        ]
        let tabs = titles.enumerated().compactMap { index, title in
            controller.createTab(
                title: title,
                icon: index == 0 ? "terminal" : "doc.text",
                isDirty: index == 2,
                showsNotificationBadge: index == 4
            )
        }
        if let selected = tabs.dropFirst(4).first ?? tabs.first {
            controller.selectTab(selected)
        }
        return controller
    }
}

private struct TabBarBackdropLabTitlebar: View {
    let variant: TabBarBackdropLabVariant
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.75)).frame(width: 8, height: 8)
                Circle().fill(Color.yellow.opacity(0.75)).frame(width: 8, height: 8)
                Circle().fill(Color.green.opacity(0.75)).frame(width: 8, height: 8)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .background(Color(nsColor: variant.surfaceColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: variant.separatorColor))
                .frame(height: 1)
        }
    }
}

private struct TabBarBackdropLabSidebar: View {
    let title: String
    let surfaceColor: NSColor
    let separatorColor: NSColor
    let trailingBorder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(index == 0 ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
                    .frame(height: 18)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: surfaceColor))
        .overlay(alignment: trailingBorder ? .trailing : .leading) {
            Rectangle()
                .fill(Color(nsColor: separatorColor))
                .frame(width: 1)
        }
    }
}

private struct TabBarBackdropLabTerminalPane: View {
    let title: String
    let color: NSColor
    let opacity: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: color.withAlphaComponent(opacity))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(String(localized: "debug.tabBarBackdropLab.terminal.prompt", defaultValue: "lawrence in ~/cmux")) \(title)")
                    .foregroundStyle(Color.green)
                Text(String(localized: "debug.tabBarBackdropLab.terminal.overflow", defaultValue: "tab titles intentionally overflow under the split buttons"))
                    .foregroundStyle(Color.white.opacity(0.78))
                Text(String(localized: "debug.tabBarBackdropLab.terminal.compare", defaultValue: "drag / resize / compare the transparent edges"))
                    .foregroundStyle(Color.white.opacity(0.52))
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(10)
        }
    }
}

// MARK: - Background Debug Window

