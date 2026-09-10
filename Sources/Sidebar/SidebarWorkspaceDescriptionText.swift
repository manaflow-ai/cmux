import CmuxFoundation
import Foundation
import SwiftUI

/// Legacy SwiftUI renderer for a workspace description in the sidebar.
@MainActor
struct SidebarWorkspaceDescriptionText: View {
    let markdown: String
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    private static let maxDisplayedLines = 12
    private static let maxDisplayedCharacters = 4096

    var renderedContent: (displayMarkdown: String, renderedMarkdown: AttributedString?) {
        let displayMarkdown = markdown.sidebarBoundedDisplayString(
            maxDisplayedLines: Self.maxDisplayedLines,
            maxDisplayedCharacters: Self.maxDisplayedCharacters
        )
        guard let renderedMarkdown = SidebarMarkdownRenderer(markdown: displayMarkdown).workspaceDescription else {
            return (displayMarkdown: displayMarkdown, renderedMarkdown: nil)
        }
        let styledMarkdown = renderedMarkdown.applyingSidebarRowLinkPolicy(
            activeForegroundColor: isActive ? activeForegroundColor : nil
        )
        return (displayMarkdown: displayMarkdown, renderedMarkdown: styledMarkdown)
    }

    var body: some View {
        let content = renderedContent
        let text: Text
        if let renderedMarkdown = content.renderedMarkdown {
            text = Text(renderedMarkdown)
        } else {
            text = Text(content.displayMarkdown)
        }
        return text
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
                    "text=\"\(logTextPreview(markdown))\""
                )
#endif
            }
            .onChange(of: markdown) { _, newValue in
#if DEBUG
                let newlineCount = newValue.reduce(into: 0) { count, character in
                    if character == "\n" { count += 1 }
                }
                cmuxDebugLog(
                    "sidebar.description.render workspaceState=change " +
                    "len=\((newValue as NSString).length) " +
                    "newlines=\(newlineCount) " +
                    "text=\"\(logTextPreview(newValue))\""
                )
#endif
            }
    }

    private var foregroundColor: Color {
        isActive ? activeForegroundColor : .secondary.opacity(0.95)
    }

    private func logTextPreview(_ text: String, limit: Int = 120) -> String {
        let escaped = text
            .replacing("\\", with: "\\\\")
            .replacing("\n", with: "\\n")
            .replacing("\r", with: "\\r")
            .replacing("\t", with: "\\t")
        guard escaped.count > limit else { return escaped }
        return "\(escaped.prefix(limit))..."
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
