#if os(iOS)
import SwiftUI

struct WorkspaceChangesToolbarButton: View {
    let filesChanged: Int
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                String(
                    localized: "workspace.changes.title",
                    defaultValue: "Changes",
                    bundle: .module
                ),
                systemImage: "plus.forwardslash.minus"
            )
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if filesChanged > 0 {
                        Text(badgeText)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 8, y: -5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(String(
            localized: "workspace.changes.title",
            defaultValue: "Changes",
            bundle: .module
        ))
        .accessibilityIdentifier("MobileChangesButton")
    }

    private var badgeText: String {
        filesChanged > 99 ? "99+" : String(filesChanged)
    }
}
#endif
