import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceRow: View {
    let workspace: MobileWorkspacePreview
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    /// When `true`, the workspace title wraps onto multiple lines instead of
    /// truncating to one (driven by the "Wrap Workspace Titles" setting).
    let wrapWorkspaceTitles: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkspaceAvatar(workspace: workspace)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(wrapWorkspaceTitles ? nil : 1)

                    Spacer(minLength: 8)

                    Text(workspace.timestampOrStatus(connectionStatus: connectionStatus))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(workspace.previewLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(workspace.statusColor(connectionStatus: connectionStatus))
                        .frame(width: 7, height: 7)

                    Text(workspace.detailLine(connectionStatus: connectionStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }
}

struct WorkspaceAvatar: View {
    let workspace: MobileWorkspacePreview

    var body: some View {
        ZStack {
            if let pictureImage {
                pictureImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(workspace.avatarGradient)
                    .frame(width: 48, height: 48)

                Image(systemName: workspace.avatarSymbolName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Resolved avatar image when the workspace has a fetched picture, else nil
    /// so the gradient + symbol fallback renders.
    private var pictureImage: Image? {
        guard let data = workspace.pictureData else { return nil }
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #elseif os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }
}
