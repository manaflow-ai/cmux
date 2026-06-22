import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// One notification row: an unread dot, the workspace/title, body, and a
/// relative timestamp. Renders an immutable value snapshot only.
struct NotificationRow: View {
    let notification: MobileNotificationPreview
    let workspaceName: String?

    /// The workspace name, falling back to a generic label when the Mac did not
    /// report one (closed or untitled workspace), so the row is never blank.
    private var workspaceLabel: String {
        let name = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return L10n.string("mobile.notifications.unknownWorkspace", defaultValue: "Workspace")
        }
        return name
    }

    private var displayTitle: String {
        if notification.isContentHidden {
            return L10n.string("mobile.notifications.hidden.title", defaultValue: "cmux")
        }
        return notification.title
    }

    private var displaySubtitle: String {
        notification.isContentHidden ? "" : notification.subtitle
    }

    private var displayBody: String {
        if notification.isContentHidden {
            return L10n.string("mobile.notifications.hidden.body", defaultValue: "New terminal activity")
        }
        return notification.body
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(notification.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspaceLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(notification.createdAt, format: .relative(presentation: .numeric))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // The title is an activity string ("Claude finished"); show it
                // under the workspace name so the row reads "<workspace> · <what
                // happened>".
                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !displaySubtitle.isEmpty {
                    Text(displaySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !displayBody.isEmpty {
                    Text(displayBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileNotificationRow-\(notification.id)")
    }
}
