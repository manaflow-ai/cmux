public import CmuxSidebarProviderKit
public import CoreGraphics
public import SwiftUI

/// The non-browser-stack body of the extension sidebar: a vertical column of
/// ``ExtensionSidebarSectionView`` sections followed by the host's empty-area
/// drop target, padded and stretched to fill the scroll viewport.
///
/// A pure presentation composite. It holds no app-target state: each section is
/// built by the `makeSection` closure (which returns the slice-2
/// ``ExtensionSidebarSectionView``), the padding/min-height metrics are passed
/// in as resolved values (the host computes `contentMinHeight` from its
/// `GeometryReader` proxy), and the app-side `SidebarEmptyArea` (which needs the
/// host's `@State`/bindings and drag controller) is injected through the
/// `emptyArea` `@ViewBuilder` slot so none of it crosses the package boundary.
public struct ExtensionSidebarSectionsColumn<EmptyArea: View>: View {
    let sections: [CmuxSidebarProviderSection]
    let rowVerticalPadding: CGFloat
    let bottomPadding: CGFloat
    let contentMinHeight: CGFloat
    let makeSection: (CmuxSidebarProviderSection) -> ExtensionSidebarSectionView
    let emptyArea: () -> EmptyArea

    /// Creates the extension-sidebar sections column.
    /// - Parameters:
    ///   - sections: The provider sections rendered top-to-bottom.
    ///   - rowVerticalPadding: Top padding applied above the first section.
    ///   - bottomPadding: Bottom padding applied below the empty area.
    ///   - contentMinHeight: The viewport-derived minimum height the column is
    ///     stretched to (computed app-side from the scroll `GeometryReader`).
    ///   - makeSection: Builds one ``ExtensionSidebarSectionView`` per section.
    ///   - emptyArea: The host's empty-area drop target, injected as a slot so
    ///     its app-side bindings and drag controller stay app-side.
    public init(
        sections: [CmuxSidebarProviderSection],
        rowVerticalPadding: CGFloat,
        bottomPadding: CGFloat,
        contentMinHeight: CGFloat,
        makeSection: @escaping (CmuxSidebarProviderSection) -> ExtensionSidebarSectionView,
        @ViewBuilder emptyArea: @escaping () -> EmptyArea
    ) {
        self.sections = sections
        self.rowVerticalPadding = rowVerticalPadding
        self.bottomPadding = bottomPadding
        self.contentMinHeight = contentMinHeight
        self.makeSection = makeSection
        self.emptyArea = emptyArea
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sections) { section in
                makeSection(section)
            }

            emptyArea()
        }
        .padding(.top, rowVerticalPadding)
        .padding(.bottom, bottomPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: contentMinHeight,
            alignment: .topLeading
        )
    }
}
