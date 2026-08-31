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
        ("web", "main", "~/repos/cmux/web"),
        ("daemon", "main", "~/repos/cmux/daemon"),
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

    static func scenes() -> [GalleryScene] {
        [
            GalleryScene(name: "filter-field-idle") {
                field(SidebarFilterFieldModel(queryText: "", matchCount: 24, totalCount: 24))
            },
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
            GalleryScene(name: "rail-resting", width: 260) {
                rail {
                    field(SidebarFilterFieldModel(queryText: "", matchCount: 6, totalCount: 6))
                } content: {
                    ForEach(Array(workspaces.enumerated()), id: \.offset) { index, workspace in
                        GalleryMockRow(
                            title: workspace.0,
                            branch: workspace.1,
                            directory: workspace.2,
                            isActive: index == 1
                        )
                    }
                }
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
        ]
    }
}
