public import CmuxSidebar
public import SwiftUI

/// Renders a workspace's keyed markdown metadata blocks in the sidebar,
/// collapsed to the first block with a "Show more details"/"Show less details"
/// toggle past the limit.
public struct SidebarMetadataMarkdownBlocks: View {
    let blocks: [SidebarMetadataBlock]
    let isActive: Bool
    let activeForegroundColor: Color
    let activeSecondaryForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedBlockLimit = 1

    /// Creates the markdown-block list.
    /// - Parameters:
    ///   - blocks: The metadata blocks to display, in render order.
    ///   - isActive: Whether the owning workspace row is the active selection.
    ///   - activeForegroundColor: Foreground color used when active.
    ///   - activeSecondaryForegroundColor: Secondary foreground used when active.
    ///   - fontScale: Multiplier applied to the base font size.
    ///   - onFocus: Invoked when a block is tapped or the toggle is pressed.
    public init(
        blocks: [SidebarMetadataBlock],
        isActive: Bool,
        activeForegroundColor: Color,
        activeSecondaryForegroundColor: Color,
        fontScale: CGFloat,
        onFocus: @escaping () -> Void
    ) {
        self.blocks = blocks
        self.isActive = isActive
        self.activeForegroundColor = activeForegroundColor
        self.activeSecondaryForegroundColor = activeSecondaryForegroundColor
        self.fontScale = fontScale
        self.onFocus = onFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleBlocks, id: \.key) { block in
                SidebarMetadataMarkdownBlockRow(
                    block: block,
                    isActive: isActive,
                    activeForegroundColor: activeForegroundColor,
                    fontScale: fontScale,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details", bundle: .main) : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details", bundle: .main)) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10 * fontScale, weight: .semibold))
                .foregroundColor(isActive ? activeSecondaryForegroundColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleBlocks: [SidebarMetadataBlock] {
        guard !isExpanded, blocks.count > collapsedBlockLimit else { return blocks }
        return Array(blocks.prefix(collapsedBlockLimit))
    }

    private var shouldShowToggle: Bool {
        blocks.count > collapsedBlockLimit
    }
}
