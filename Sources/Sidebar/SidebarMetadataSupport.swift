import AppKit
import Bonsplit
import SwiftUI

struct SidebarWorkspaceDescriptionText: View {
    let markdown: String
    let isActive: Bool

    var body: some View {
        let renderedMarkdown = SidebarMarkdownRenderer.renderWorkspaceDescription(markdown)
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
            } else {
                Text(markdown)
            }
        }
        .font(.system(size: 10.5))
        .foregroundColor(foregroundColor)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("SidebarWorkspaceDescriptionText")
        .accessibilityLabel(accessibilityText(renderedMarkdown: renderedMarkdown))
        .onAppear {
#if DEBUG
            let newlineCount = markdown.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
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
            dlog(
                "sidebar.description.render workspaceState=change " +
                "len=\((newValue as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(newValue))\""
            )
#endif
        }
    }

    private var foregroundColor: Color {
        isActive ? .white.opacity(0.84) : .secondary.opacity(0.95)
    }

    private func accessibilityText(renderedMarkdown: AttributedString?) -> String {
        if let renderedMarkdown {
            return String(renderedMarkdown.characters)
        }
        return markdown
    }
}

enum SidebarMarkdownRenderer {
    static func renderWorkspaceDescription(_ markdown: String) -> AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}

struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(entry: entry, isActive: isActive, onFocus: onFocus)
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less") : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? activeSecondaryTextColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
    }

    private var activeSecondaryTextColor: Color {
        Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.65))
    }

    private var visibleEntries: [SidebarStatusEntry] {
        guard !isExpanded, entries.count > collapsedEntryLimit else { return entries }
        return Array(entries.prefix(collapsedEntryLimit))
    }

    private var helpText: String {
        entries.map { entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.key : trimmed
        }
        .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > collapsedEntryLimit
    }
}

private struct SidebarMetadataEntryRow: View {
    let entry: SidebarStatusEntry
    let isActive: Bool
    let onFocus: () -> Void

    var body: some View {
        Group {
            if let url = entry.url {
                Button {
                    onFocus()
                    NSWorkspace.shared.open(url)
                } label: {
                    rowContent(underlined: true)
                }
                .buttonStyle(.plain)
                .safeHelp(url.absoluteString)
            } else {
                rowContent(underlined: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
            }
        }
    }

    @ViewBuilder
    private func rowContent(underlined: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon = iconView {
                icon
                    .foregroundColor(foregroundColor.opacity(0.95))
            }
            metadataText(underlined: underlined)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foregroundColor: Color {
        if isActive,
           let raw = entry.color,
           Color(hex: raw) != nil {
            return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.95))
        }
        if let raw = entry.color, let explicit = Color(hex: raw) {
            return explicit
        }
        return isActive ? .white.opacity(0.8) : .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return nil
        }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: 9)))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: 8, weight: .semibold)))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(Image(systemName: symbolName).font(.system(size: 8, weight: .medium)))
    }

    @ViewBuilder
    private func metadataText(underlined: Bool) -> some View {
        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? entry.key : trimmed
        if entry.format == .markdown,
           let attributed = try? AttributedString(
                markdown: display,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        } else {
            Text(display)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        }
    }
}

struct SidebarMetadataMarkdownBlocks: View {
    let blocks: [SidebarMetadataBlock]
    let isActive: Bool
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedBlockLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleBlocks, id: \.key) { block in
                SidebarMetadataMarkdownBlockRow(
                    block: block,
                    isActive: isActive,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details") : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .white.opacity(0.65) : .secondary.opacity(0.9))
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

private struct SidebarMetadataMarkdownBlockRow: View {
    let block: SidebarMetadataBlock
    let isActive: Bool
    let onFocus: () -> Void

    @State private var renderedMarkdown: AttributedString?

    var body: some View {
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
                    .foregroundColor(foregroundColor)
            } else {
                Text(block.markdown)
                    .foregroundColor(foregroundColor)
            }
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onAppear(perform: renderMarkdown)
        .onChange(of: block.markdown) { _ in
            renderMarkdown()
        }
    }

    private var foregroundColor: Color {
        isActive ? .white.opacity(0.8) : .secondary
    }

    private func renderMarkdown() {
        renderedMarkdown = try? AttributedString(
            markdown: block.markdown,
            options: .init(interpretedSyntax: .full)
        )
    }
}
