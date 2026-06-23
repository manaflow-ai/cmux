public import AppKit
public import SwiftUI

/// The header strip shown above file-backed panels (markdown, file preview):
/// a leading SF Symbol, the middle-truncated, selectable file path, then any
/// caller-supplied trailing controls.
///
/// Shared panel chrome with no app-target coupling, so it lives in `CmuxPanes`
/// beside the ``Panel`` protocol.
public struct PanelFilePathHeader<TrailingContent: View>: View {
    private let iconSystemName: String
    private let filePath: String
    private let foregroundColor: NSColor
    @ViewBuilder private let trailingContent: () -> TrailingContent

    /// Create a file-path header.
    /// - Parameters:
    ///   - iconSystemName: SF Symbol drawn at the leading edge.
    ///   - filePath: The path text, middle-truncated and text-selectable.
    ///   - foregroundColor: Base color for the path text (rendered at 0.68
    ///     opacity).
    ///   - trailingContent: Controls placed at the trailing edge.
    public init(
        iconSystemName: String,
        filePath: String,
        foregroundColor: NSColor,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.iconSystemName = iconSystemName
        self.filePath = filePath
        self.foregroundColor = foregroundColor
        self.trailingContent = trailingContent
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailingContent()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.clear)
    }
}
