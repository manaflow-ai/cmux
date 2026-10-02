#if os(iOS)
import SwiftUI

struct WorkspaceChangesHintBanner: View {
    let openChanges: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: openChanges) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(
                            localized: "workspace.changes.hint.title",
                            defaultValue: "Review this workspace's changes",
                            bundle: .module
                        ))
                        .font(.subheadline.weight(.semibold))
                        Text(String(
                            localized: "workspace.changes.hint.body",
                            defaultValue: "Tap the Changes button to see what the agent edited.",
                            bundle: .module
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .padding(5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "workspace.changes.hint.dismiss",
                defaultValue: "Dismiss",
                bundle: .module
            ))
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("MobileChangesHint")
    }
}
#endif
