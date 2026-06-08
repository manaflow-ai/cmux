#if os(iOS) && DEBUG
import CmuxMobileShellModel
import SwiftUI

/// The scrollable list of checklist questions in the dogfood pane.
///
/// Snapshot-boundary clean: it holds only value snapshots (the immutable
/// ``items`` and the current ``selections`` map) plus a `select` closure, never a
/// reference to ``DogfoodFeedbackModel``. Pulling this out of
/// ``DogfoodPaneOverlayView`` means a freeform-note keystroke (a write to
/// `model.note`) does not invalidate the checklist rows, only the note editor —
/// the orthogonal-`@Observable`-change thrash the snapshot-boundary rule exists
/// to prevent.
///
/// DEV-only; strings are not localized.
struct DogfoodChecklistSection: View {
    let items: [DogfoodChecklistItem]
    let selections: [String: String]
    let select: (String, String) -> Void

    var body: some View {
        if items.isEmpty {
            Text("No checklist pushed yet. The agent can push one with the dogfood_checklist_set debug command.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        DogfoodChecklistRow(
                            item: item,
                            selection: selections[item.id],
                            select: { choice in select(item.id, choice) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)
        }
    }
}
#endif
