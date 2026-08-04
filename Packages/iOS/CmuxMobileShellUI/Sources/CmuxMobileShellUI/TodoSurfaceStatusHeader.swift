import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Status and Mac-open controls above the native mobile checklist.
struct TodoSurfaceStatusHeader: View {
    let title: String
    let status: MobileTodoStatus
    let statusHidden: Bool
    let isEnabled: Bool
    let cycleStatus: () -> Void
    let setStatus: (MobileTodoStatus?) -> Void
    let openOnMac: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: cycleStatus) {
                Label(
                    statusHidden
                        ? L10n.string("mobile.todo.status.hidden", defaultValue: "No Status")
                        : status.displayName,
                    systemImage: statusHidden ? "circle.slash" : status.systemImage
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(L10n.string("mobile.todo.status.cycle", defaultValue: "Cycle status"))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusHidden
                    ? L10n.string("mobile.todo.status.hidden", defaultValue: "No Status")
                    : status.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Menu {
                Button(L10n.string("mobile.todo.status.automatic", defaultValue: "Automatic")) {
                    setStatus(nil)
                }
                ForEach(MobileTodoStatus.allCases, id: \.self) { lane in
                    Button(lane.displayName) { setStatus(lane) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(!isEnabled)
            .accessibilityLabel(L10n.string("mobile.todo.status.choose", defaultValue: "Choose status"))

            Button(action: openOnMac) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(L10n.string("mobile.surface.openOnMac", defaultValue: "Open on Mac"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
