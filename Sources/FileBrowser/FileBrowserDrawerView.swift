import SwiftUI

/// Structural container for the file browser drawer.
/// Shows the file browser tree with a spacer for titlebar button clearance.
struct FileBrowserDrawerView: View {
    let directory: String?
    let onFileSelected: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Empty header bar for titlebar button clearance.
                Spacer()
                    .frame(height: 28)
                Divider()

                if let directory {
                    FileBrowserView(
                        rootPath: directory,
                        onFileSelected: onFileSelected
                    )
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)

            // Visible right-edge divider so users can find the resize handle.
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(String(localized: "fileBrowser.emptyState", defaultValue: "Focus a terminal to browse its working directory."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.95, alpha: 1.0))
    }
}
