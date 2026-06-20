#if canImport(AppKit)

internal import SwiftUI
internal import Bonsplit

/// One preview tile in ``TabBarBackdropLabView``: a sample sidebar/titlebar/`Bonsplit`
/// pane stack rendering a single ``TabBarBackdropLabVariant`` with overflow tabs
/// under the split buttons.
///
/// The sample owns its own `Bonsplit` controller seeded with fixed demo tabs and
/// re-applies the variant's configuration whenever the variant's render identity
/// changes. The production tab-bar height is threaded in from the lab's injected
/// ``TabBarBackdropLabInputs`` so the sample matches production proportions.
struct TabBarBackdropLabSample: View {
    let variant: TabBarBackdropLabVariant
    let sidebarWidth: CGFloat
    let tabBarHeight: CGFloat
    @State private var controller: BonsplitController

    init(variant: TabBarBackdropLabVariant, sidebarWidth: CGFloat, tabBarHeight: CGFloat) {
        self.variant = variant
        self.sidebarWidth = sidebarWidth
        self.tabBarHeight = tabBarHeight
        _controller = State(initialValue: Self.makeController(for: variant, tabBarHeight: tabBarHeight))
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
        controller.configuration = Self.makeConfiguration(for: variant, tabBarHeight: tabBarHeight)
    }

    private static func makeAppearance(for variant: TabBarBackdropLabVariant, tabBarHeight: CGFloat) -> BonsplitConfiguration.Appearance {
        BonsplitConfiguration.Appearance(
            tabBarHeight: tabBarHeight,
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

    private static func makeConfiguration(for variant: TabBarBackdropLabVariant, tabBarHeight: CGFloat) -> BonsplitConfiguration {
        BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowTabReordering: false,
            allowCrossPaneTabMove: false,
            autoCloseEmptyPanes: false,
            contentViewLifecycle: .recreateOnSwitch,
            newTabPosition: .end,
            appearance: makeAppearance(for: variant, tabBarHeight: tabBarHeight)
        )
    }

    private static func makeController(for variant: TabBarBackdropLabVariant, tabBarHeight: CGFloat) -> BonsplitController {
        let controller = BonsplitController(configuration: makeConfiguration(for: variant, tabBarHeight: tabBarHeight))

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

#endif
