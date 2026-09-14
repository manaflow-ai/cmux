import CmuxFoundation
import SwiftUI

#if DEBUG
/// An inline notification; presentation never creates a window or takes focus.
struct SidebarCloudAnnouncementView: View {
    let style: CloudAnnouncementPreviewStyle
    let accent: Color
    let helpMidX: CGFloat
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var isHovering = false

    private let title = String(localized: "sidebar.cloudAnnouncement.title", defaultValue: "cmux Cloud is here")
    private let changelog = String(localized: "sidebar.cloudAnnouncement.changelog", defaultValue: "Read the changelog")
    private let dismiss = String(localized: "sidebar.cloudAnnouncement.dismiss", defaultValue: "Dismiss announcement")

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                content
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(changelog)
            .accessibilityIdentifier("CloudAnnouncementOpen")
            .accessibilityAction(named: Text(dismiss), onDismiss)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .cmuxFont(size: 9, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
            .accessibilityLabel(dismiss)
            .accessibilityIdentifier("CloudAnnouncementDismiss")
        }
        .background { background }
        .overlay(alignment: .leading) {
            if style == .notificationRow {
                Capsule()
                    .fill(accent.opacity(0.8))
                    .frame(width: 2, height: 36)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if style == .nativeHint {
                CloudAnnouncementPointer()
                    .fill(.regularMaterial)
                    .frame(width: 8, height: 5)
                    .offset(x: max(8, helpMidX - 10), y: 4)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, style == .nativeHint ? 4 : 0)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(changelog, action: onOpen)
            Button(dismiss, action: onDismiss)
        }
    }

    private var height: CGFloat {
        switch style {
        case .footerNote: 58
        case .nativeHint: 59
        case .notificationRow, .updatePill: 56
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            if style == .nativeHint {
                Image(systemName: "cloud")
                    .cmuxFont(size: 13)
                    .foregroundStyle(accent.opacity(0.85))
                    .padding(.top, 2)
            }
            if style == .footerNote {
                Circle()
                    .fill(accent.opacity(0.8))
                    .frame(width: 4, height: 4)
                    .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .cmuxFont(size: style == .footerNote ? 11 : 11.5, weight: .medium)
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(changelog)
                        .cmuxFont(size: 10.5)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .cmuxFont(size: 8)
                }
                .foregroundStyle(accent.opacity(style == .footerNote ? 0.75 : 0.95))
            }
        }
        .padding(.leading, style == .footerNote ? 2 : 12)
        .padding(.trailing, 23)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .notificationRow:
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(isHovering ? 0.055 : 0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.045))
                }
        case .footerNote:
            Color.clear
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                }
        case .nativeHint:
            RoundedRectangle(cornerRadius: 6)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        case .updatePill:
            Color.clear
        }
    }
}
#endif
