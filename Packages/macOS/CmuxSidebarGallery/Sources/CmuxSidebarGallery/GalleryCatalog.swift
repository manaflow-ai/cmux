import CmuxSidebar
import SwiftUI

/// The scenes the gallery renders.
///
/// Fields are drawn through ``SidebarFilterFieldChrome`` with a static `Text`
/// standing in for the live `TextField`: `ImageRenderer` cannot rasterise
/// AppKit-backed controls, and the chrome is what is being reviewed here
/// anyway.
@MainActor
struct GalleryCatalog {
    /// cmux's sidebar accent, matching `cmuxAccentNSColor(for:)`.
    static let accent = Color(.sRGB, red: 0, green: 145.0 / 255.0, blue: 1, opacity: 1)

    /// A non-editable stand-in for the live text field.
    @ViewBuilder
    static func staticInput(_ text: String, metrics: SidebarFilterMetrics) -> some View {
        if text.isEmpty {
            Text(verbatim: "Filter workspaces")
                .font(.system(size: metrics.queryFontSize))
                .foregroundStyle(.tertiary)
        } else {
            Text(verbatim: text)
                .font(.system(size: metrics.queryFontSize))
                .foregroundStyle(.primary)
        }
    }

    static func field(
        _ model: SidebarFilterFieldModel,
        isFocused: Bool = false
    ) -> some View {
        let metrics = SidebarFilterMetrics()
        // A sigil scopes the query, so the chip replaces it in the visible text.
        let visible = model.scopeField == nil
            ? model.queryText
            : String(model.queryText.dropFirst())
        return SidebarFilterFieldChrome(
            model: model,
            metrics: metrics,
            accent: accent,
            isFocused: isFocused,
            onCancel: {}
        ) {
            staticInput(visible, metrics: metrics)
        }
    }

    // MARK: - Fixtures

    static let workspaces: [(String, String, String)] = [
        ("cmux", "main", "~/repos/cmux"),
        ("sidebar drag fix", "fix/sidebar-drag-failsafe", "~/repos/cmux"),
        ("ghostty", "cmux-fork", "~/repos/ghostty"),
        ("dragnet", "feat/drag-reorder", "~/repos/dragnet"),
    ]

    @ViewBuilder
    static func rail<Header: View, Body: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
        }
    }

    /// The full rail contents: filter field, rows, footer action.
    @ViewBuilder
    static func railContents(
        mode: SidebarPresentationMode,
        filter: SidebarFilterFieldModel,
        activeIndex: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                field(filter, isFocused: filter.hasQuery)
                SidebarPresentationToggleButton(mode: mode, accent: accent, onToggle: {})
                    .padding(.trailing, 8)
            }
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(workspaces.enumerated()), id: \.offset) { index, workspace in
                    GalleryMockRow(
                        title: workspace.0,
                        branch: workspace.1,
                        directory: workspace.2,
                        isActive: index == activeIndex
                    )
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 8)
            Divider().opacity(0.4).padding(.horizontal, 8)
            SidebarNewWorkspaceButton(accent: accent, onCreate: {})
                .padding(.vertical, 6)
        }
    }

    static let sceneWidth: CGFloat = 620
    static let sceneHeight: CGFloat = 400
    static let railWidth: CGFloat = 260

    /// The floating panel over mock terminal content, as it appears on reveal.
    static func floatingOverContent(filter: SidebarFilterFieldModel) -> some View {
        ZStack(alignment: .topLeading) {
            GalleryTerminalBackdrop()
            SidebarPeekPanelChrome {
                railContents(mode: .floating, filter: filter)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: railWidth + SidebarPeekPanelMetrics.default.leadingInset)
        }
        .frame(width: sceneWidth, height: sceneHeight)
        .clipped()
    }

    /// The docked sidebar beside the same content, for the mode comparison.
    static func dockedBesideContent(filter: SidebarFilterFieldModel) -> some View {
        HStack(spacing: 0) {
            railContents(mode: .docked, filter: filter)
                .frame(width: railWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.primary.opacity(0.04))
            Divider().opacity(0.5)
            GalleryTerminalBackdrop()
        }
        .frame(width: sceneWidth, height: sceneHeight)
        .clipped()
    }

    static func scenes() -> [GalleryScene] {
        let resting = SidebarFilterFieldModel(queryText: "", matchCount: 6, totalCount: 6)
        return [
            GalleryScene(name: "filter-field-scoped") {
                field(
                    SidebarFilterFieldModel(
                        queryText: "@fix-drag",
                        matchCount: 2,
                        totalCount: 24,
                        scopeField: .branch
                    ),
                    isFocused: true
                )
            },
            GalleryScene(name: "rail-filtering", width: 260) {
                rail {
                    field(
                        SidebarFilterFieldModel(queryText: "drag", matchCount: 2, totalCount: 6),
                        isFocused: true
                    )
                } content: {
                    GalleryMockRow(
                        title: "sidebar drag fix",
                        branch: "fix/sidebar-drag-failsafe",
                        directory: "~/repos/cmux",
                        isActive: true,
                        titleRanges: [8..<12]
                    )
                    GalleryMockRow(
                        title: "dragnet",
                        branch: "feat/drag-reorder",
                        directory: "~/repos/dragnet",
                        titleRanges: [0..<4]
                    )
                }
            },
            GalleryScene(name: "rail-empty-result", width: 260) {
                rail {
                    field(
                        SidebarFilterFieldModel(queryText: "zzzz", matchCount: 0, totalCount: 6),
                        isFocused: true
                    )
                } content: {
                    SidebarFilterEmptyStateView(queryText: "zzzz", accent: accent, onClear: {})
                }
            },
            GalleryScene(name: "peek-floating", width: sceneWidth) {
                floatingOverContent(filter: resting)
            },
            GalleryScene(name: "peek-docked", width: sceneWidth) {
                dockedBesideContent(filter: resting)
            },
        ]
    }
}
