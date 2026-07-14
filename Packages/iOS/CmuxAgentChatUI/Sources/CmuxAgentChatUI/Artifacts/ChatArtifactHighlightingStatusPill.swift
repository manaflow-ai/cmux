import Foundation
import SwiftUI

/// A compact, expandable explanation for syntax highlighting disabled by file size.
struct ChatArtifactHighlightingStatusPill: View {
    let actualBytes: Int64
    let maximumBytes: Int64

    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "paintbrush.slash")
                    .imageScale(.small)
                if isExpanded {
                    Text(explanation)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(
                        localized: "chat.artifact.highlighting.off",
                        defaultValue: "Highlighting off",
                        bundle: .module
                    ))
                    .font(.caption.weight(.semibold))
                }
                Image(systemName: isExpanded ? "xmark.circle.fill" : "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: isExpanded ? 360 : nil, alignment: .leading)
            .background(.thinMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isExpanded)
    }

    private var explanation: String {
        let format = String(
            localized: "chat.artifact.highlighting.off.explanation",
            defaultValue: "This file is %@. Syntax highlighting is off above %@ to keep scrolling smooth.",
            bundle: .module
        )
        return String.localizedStringWithFormat(
            format,
            ByteCountFormatter.string(fromByteCount: actualBytes, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)
        )
    }
}
