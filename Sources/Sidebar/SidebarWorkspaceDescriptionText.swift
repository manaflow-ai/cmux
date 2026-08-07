import CmuxFoundation
import Foundation
import SwiftUI

/// Legacy SwiftUI renderer for a workspace description in the sidebar.
@MainActor
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
        guard var renderedMarkdown = SidebarMarkdownRenderer(markdown: displayMarkdown).workspaceDescription else {
            return RenderedContent(displayMarkdown: displayMarkdown, renderedMarkdown: nil)
        }
        let linkRuns = renderedMarkdown.runs.compactMap { run in
            run.link.map { (range: run.range, url: $0) }
        }
        for linkRun in linkRuns {
            guard let scheme = linkRun.url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                renderedMarkdown[linkRun.range].link = nil
                continue
            }
            if isActive {
                renderedMarkdown[linkRun.range].foregroundColor = activeForegroundColor
            }
        }
        return RenderedContent(displayMarkdown: displayMarkdown, renderedMarkdown: renderedMarkdown)
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
            .onChange(of: markdown) { newValue in
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
