import CmuxFoundation
import CmuxTextActions
import SwiftUI

/// One snippet in the sidebar list: title, optional category tag, and the
/// first line of the text. Click selects and delivers.
struct SnippetsSidebarRow: View {
    let entry: CmuxSnippetMenuEntry
    let isSelected: Bool
    let onActivate: () -> Void

    private var preview: String {
        entry.payload.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .cmuxFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                    if let category = entry.category {
                        Text(category)
                            .cmuxFont(size: 9, weight: .medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.16)))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(preview)
                    .cmuxFont(size: 11, design: .monospaced)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, RightSidebarChromeMetrics.contentIconLeadingPadding)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SnippetsSidebarRow-\(entry.actionID)")
    }
}
