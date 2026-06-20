import CmuxFoundation
import CmuxSidebar
import SwiftUI

/// One markdown metadata block in the sidebar list, rendered inline (memoized)
/// so the first render is already attributed and the row stays height-stable.
struct SidebarMetadataMarkdownBlockRow: View {
    let block: SidebarMetadataBlock
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void
    private static let maxDisplayedLines = 12
    private static let maxDisplayedCharacters = 4096

    var body: some View {
        // Render inline (memoized) so the FIRST render is already attributed.
        // Parsing in onAppear into @State performed a guaranteed nil ->
        // attributed swap on every first appearance, changing the row's height
        // mid-scroll and re-feeding the sidebar-wide layout cycle (#5764).
        let displayMarkdown = Self.displayMarkdown(from: block.markdown)
        let renderedMarkdown = SidebarMetadataMarkdownRenderer.rendered(displayMarkdown)
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
                    .foregroundColor(foregroundColor)
            } else {
                Text(displayMarkdown)
                    .foregroundColor(foregroundColor)
            }
        }
        .font(.system(size: 10 * fontScale))
        .multilineTextAlignment(.leading)
        .lineLimit(Self.maxDisplayedLines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private var foregroundColor: Color {
        isActive ? activeForegroundColor : .secondary
    }

    private static func displayMarkdown(from markdown: String) -> String {
        markdown.sidebarBoundedDisplayString(
            maxDisplayedLines: maxDisplayedLines,
            maxDisplayedCharacters: maxDisplayedCharacters
        )
    }
}
