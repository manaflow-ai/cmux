import CmuxAppKitSupportUI
import CmuxFoundation
import Combine
import SwiftUI

/// First-party leading sidebar column for selecting creation defaults.
///
/// Contexts use the same list metrics, palette, and row surface as workspaces.
/// The column contributes data and selection behavior, not machine-only chrome.
struct SidebarCreationContextColumn: View {
    @EnvironmentObject private var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent
    @StateObject private var rowSettingsStore = SidebarListRowSettingsStore(
        initialSidebarFontSize: GhosttyConfig.load().sidebarFontSize
    )
    @State private var observationRevision: UInt64 = 0

    var body: some View {
        let _ = observationRevision
        let contexts = tabManager.sidebarCreationContextSnapshots()
        let settings = rowSettingsStore.snapshot

        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(contexts) { context in
                    contextRow(context, settings: settings)
                }
            }
            .padding(.vertical, SidebarListMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: SidebarListMetrics.scrollTopInset)
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: SidebarListMetrics.bottomScrimHeight)
                .allowsHitTesting(false)
        }
        .mask {
            SidebarWorkspaceScrollEdgeFadeMask(
                topHeight: SidebarListMetrics.topScrimHeight,
                bottomHeight: SidebarListMetrics.bottomScrimHeight
            )
        }
        .overlay(alignment: .top) {
            WindowDragHandleView()
                .frame(height: WindowChromeMetrics.appTitlebarHeight)
                .background(TitlebarDoubleClickMonitorView())
        }
        .background(Color.clear)
        .modifier(ClearScrollBackground())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("SidebarContextColumn")
        .onReceive(remoteObservationPublisher) { _ in
            observationRevision &+= 1
        }
    }

    private var remoteObservationPublisher: AnyPublisher<Void, Never> {
        Publishers.MergeMany(tabManager.tabs.flatMap { workspace in
            [
                workspace.sidebarImmediateObservationPublisher,
                workspace.sidebarObservationPublisher,
            ]
        })
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    private func contextRow(
        _ context: SidebarCreationContextSnapshot,
        settings: SidebarTabItemSettingsSnapshot
    ) -> some View {
        let palette = SidebarListRowPalette(
            isActive: context.isSelected,
            colorScheme: colorScheme,
            selectionColorHex: settings.selectionColorHex
        )
        let backgroundStyle = sidebarListRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: context.isSelected,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex
        )
        let usesBorder = context.isSelected && settings.activeTabIndicatorStyle == .solidFill

        return Button {
            _ = tabManager.selectSidebarCreationContext(id: context.id)
        } label: {
            VStack(alignment: .leading, spacing: SidebarListMetrics.rowContentSpacing) {
                Text(context.title)
                    .font(rowFont(
                        SidebarListMetrics.titleFontSize,
                        weight: .semibold,
                        settings: settings
                    ))
                    .foregroundColor(Color(nsColor: palette.primary))
                    .lineLimit(settings.wrapsWorkspaceTitles ? 8 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(context.subtitle)
                    .font(rowFont(SidebarListMetrics.subtitleFontSize, settings: settings))
                    .foregroundColor(Color(nsColor: palette.secondary(0.8)))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarListRowSurface(
                backgroundStyle: backgroundStyle,
                borderColor: usesBorder ? Color.primary.opacity(0.5) : .clear,
                borderLineWidth: usesBorder ? 1.5 : 0
            )
            .sidebarListRowOuterChrome()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SidebarContextRow.\(context.id)")
        .accessibilityLabel(context.title)
        .help(context.subtitle)
    }

    private func rowFont(
        _ baseSize: CGFloat,
        weight: Font.Weight = .regular,
        settings: SidebarTabItemSettingsSnapshot
    ) -> Font {
        Font.system(
            size: GlobalFontMagnification.scaledSize(
                baseSize * settings.sidebarFontScale,
                percent: globalFontMagnificationPercent
            ),
            weight: weight
        )
    }
}
