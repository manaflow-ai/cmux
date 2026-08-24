#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The horizontally scrolling liquid-glass chips of recently used
/// directories, shown under the search bar of a browse screen. Tapping a
/// chip pushes that folder onto the browse stack.
struct TaskComposerDirectoryRecentChipsRow: View {
    let recents: [MobileTaskDirectoryCandidate]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(recents.enumerated()), id: \.element.id) { index, candidate in
                    TaskComposerDirectoryRecentChip(
                        candidate: candidate,
                        identifier: "MobileTaskDirectoryRecent\(index)"
                    )
                }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .contentMargins(.vertical, 8, for: .scrollContent)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct TaskComposerDirectoryRecentChip: View {
    let candidate: MobileTaskDirectoryCandidate
    let identifier: String

    var body: some View {
        NavigationLink(value: TaskComposerDirectoryBrowseDestination(path: candidate.path)) {
            Label(
                TaskComposerDirectoryDisplayPath(path: candidate.path).name,
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .mobileGlassPill()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TaskComposerDirectoryDisplayPath(path: candidate.path).name)
        .accessibilityValue(candidate.path)
        .accessibilityHint(
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.open.hint",
                defaultValue: "Shows the folders inside this folder."
            )
        )
        .accessibilityIdentifier(identifier)
    }
}
#endif
