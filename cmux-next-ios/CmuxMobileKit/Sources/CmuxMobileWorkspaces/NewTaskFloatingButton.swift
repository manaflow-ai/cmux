#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// New Task: the floating compose button at the bottom trailing corner of Workspaces, above the
/// tab bar, where Slack puts its compose button (2026-11-18). It opens the task composer (a
/// prompt, the agents that run it and where). It used to be the first row of New Workspace's
/// long-press menu, where it was hidden behind a press and crowded by fourteen other rows.
struct NewTaskFloatingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.colors.onAccent.color)
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .buttonStyle(CmuxMobilePressFillStyle(cornerRadius: Self.size / 2))
        .glassEffect(.regular.tint(theme.colors.accent.color).interactive(), in: .circle)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityLabel("New Task")
        .accessibilityHint("Write a prompt and choose the agents that run it")
        .accessibilityIdentifier("workspaces.newTask")
    }

    /// Slack's and Material's compose button: 56 pt, above the 44 pt minimum target.
    static let size: CGFloat = 56
}
#endif
