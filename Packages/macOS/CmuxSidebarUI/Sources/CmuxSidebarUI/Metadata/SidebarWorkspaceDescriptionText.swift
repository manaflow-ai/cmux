import CmuxFoundation
public import SwiftUI

/// Renders a workspace's custom description markdown in the sidebar, bounded to
/// a fixed line/character budget and rendered inline so the row is
/// height-stable on first appearance.
///
/// The optional ``debugLog`` closure receives `(phase, markdown)` on appear and
/// on every markdown change; the app target wires it to the DEBUG sidebar
/// render log. It is `nil` (a no-op) in release, preserving the original
/// app-target behavior where the log block was `#if DEBUG`-only.
public struct SidebarWorkspaceDescriptionText: View {
    let markdown: String
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let debugLog: ((_ phase: String, _ markdown: String) -> Void)?
    private static let maxDisplayedLines = 12
    private static let maxDisplayedCharacters = 4096

    /// Creates the workspace-description text view.
    /// - Parameters:
    ///   - markdown: The raw workspace-description markdown.
    ///   - isActive: Whether the owning workspace row is the active selection.
    ///   - activeForegroundColor: Foreground color used when active.
    ///   - fontScale: Multiplier applied to the base font size.
    ///   - debugLog: Optional `(phase, markdown)` sink invoked on appear and on
    ///     markdown change; pass `nil` to disable (release behavior).
    public init(
        markdown: String,
        isActive: Bool,
        activeForegroundColor: Color,
        fontScale: CGFloat,
        debugLog: ((_ phase: String, _ markdown: String) -> Void)? = nil
    ) {
        self.markdown = markdown
        self.isActive = isActive
        self.activeForegroundColor = activeForegroundColor
        self.fontScale = fontScale
        self.debugLog = debugLog
    }

    public var body: some View {
        let displayMarkdown = markdown.sidebarBoundedDisplayString(
            maxDisplayedLines: Self.maxDisplayedLines,
            maxDisplayedCharacters: Self.maxDisplayedCharacters
        )
        let renderedMarkdown = SidebarMarkdownRenderer(markdown: displayMarkdown).workspaceDescription
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
            } else {
                Text(displayMarkdown)
            }
        }
        .font(.system(size: 10.5 * fontScale))
        .foregroundColor(foregroundColor)
        .multilineTextAlignment(.leading)
        .lineLimit(Self.maxDisplayedLines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("SidebarWorkspaceDescriptionText")
        .accessibilityLabel(accessibilityText(renderedMarkdown: renderedMarkdown, displayMarkdown: displayMarkdown))
        .onAppear {
            debugLog?("appear", markdown)
        }
        .onChange(of: markdown) { _, newValue in
            debugLog?("change", newValue)
        }
    }

    private var foregroundColor: Color {
        isActive ? activeForegroundColor : .secondary.opacity(0.95)
    }

    private func accessibilityText(renderedMarkdown: AttributedString?, displayMarkdown: String) -> String {
        if let renderedMarkdown {
            return String(renderedMarkdown.characters)
        }
        return displayMarkdown
    }
}
