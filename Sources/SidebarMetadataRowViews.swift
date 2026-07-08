import AppKit
import CmuxFoundation
import CmuxSidebar
import SwiftUI

/// Sidebar keyed metadata rows reported over the control socket
/// (`set_status`/`report_meta`): the expandable list plus its private entry
/// row. Rows receive immutable value snapshots and closure action bundles
/// only, per the sidebar list snapshot-boundary rule.
struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let activeForegroundColor: Color
    let activeSecondaryForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(
                    entry: entry,
                    isActive: isActive,
                    activeForegroundColor: activeForegroundColor,
                    fontScale: fontScale,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less") : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .cmuxFont(size: 10 * fontScale, weight: .semibold)
                .foregroundColor(isActive ? activeSecondaryForegroundColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
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
    let activeForegroundColor: Color
    let fontScale: CGFloat
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
        .cmuxFont(size: 10 * fontScale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foregroundColor: Color {
        if isActive,
           let raw = entry.color,
           Color(hex: raw) != nil {
            return activeForegroundColor
        }
        if let raw = entry.color, let explicit = Color(hex: raw) {
            return explicit
        }
        return isActive ? activeForegroundColor.opacity(0.84) : .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return nil
        }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 9 * fontScale))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 8 * fontScale, weight: .semibold))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(CmuxSystemSymbolImage(magnified: symbolName, pointSize: 8 * fontScale, weight: .medium))
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
