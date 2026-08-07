import CmuxFoundation
import SwiftUI

/// Legacy SwiftUI renderer for a workspace description in the sidebar.
struct SidebarWorkspaceDescriptionText: View {
    struct RenderedContent {
        let displayMarkdown: String
        let renderedMarkdown: AttributedString?
    }

    let markdown: String
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    private static let maxDisplayedLines = 12
    private static let maxDisplayedCharacters = 4096

    var renderedContent: RenderedContent {
        let displayMarkdown = markdown.sidebarBoundedDisplayString(
            maxDisplayedLines: Self.maxDisplayedLines,
            maxDisplayedCharacters: Self.maxDisplayedCharacters
        )
        return RenderedContent(
            displayMarkdown: displayMarkdown,
            renderedMarkdown: SidebarMarkdownRenderer(markdown: displayMarkdown).workspaceDescription
        )
    }

    var body: some View {
        let content = renderedContent
        Group {
            if let renderedMarkdown = content.renderedMarkdown {
                Text(renderedMarkdown)
            } else {
                Text(content.displayMarkdown)
            }
        }
        .cmuxFont(size: 10.5 * fontScale)
        .foregroundColor(foregroundColor)
        .multilineTextAlignment(.leading)
        .lineLimit(Self.maxDisplayedLines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("SidebarWorkspaceDescriptionText")
        .accessibilityLabel(
            accessibilityText(
                renderedMarkdown: content.renderedMarkdown,
                displayMarkdown: content.displayMarkdown
            )
        )
        .onAppear {
#if DEBUG
            let newlineCount = markdown.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "sidebar.description.render workspaceState=appear " +
                "len=\((markdown as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(markdown))\""
            )
#endif
        }
        .onChange(of: markdown) { newValue in
#if DEBUG
            let newlineCount = newValue.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "sidebar.description.render workspaceState=change " +
                "len=\((newValue as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(newValue))\""
            )
#endif
        }
    }

    private var foregroundColor: Color {
        isActive ? activeForegroundColor : .secondary.opacity(0.95)
    }

    private func accessibilityText(
        renderedMarkdown: AttributedString?,
        displayMarkdown: String
    ) -> String {
        if let renderedMarkdown {
            return String(renderedMarkdown.characters)
        }
        return displayMarkdown
    }
}
