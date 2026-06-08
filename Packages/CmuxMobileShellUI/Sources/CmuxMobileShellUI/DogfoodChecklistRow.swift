#if os(iOS) && DEBUG
import CmuxMobileShellModel
import SwiftUI

/// One checklist question in the dogfood pane, rendered as a prompt plus a
/// segmented set of choice buttons.
///
/// Snapshot-boundary clean: it holds only value snapshots (the ``item`` and the
/// current ``selection``) plus a `select` closure, never a reference to
/// ``DogfoodFeedbackModel``. So an unrelated change in the model (a different
/// item's answer, the freeform note) cannot invalidate every row in the
/// enclosing `ForEach`. DEV-only; strings are not localized.
struct DogfoodChecklistRow: View {
    let item: DogfoodChecklistItem
    let selection: String?
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.prompt)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(item.choices, id: \.self) { choice in
                    Button {
                        select(choice)
                    } label: {
                        Text(choice)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selection == choice ? Color.accentColor : Color.secondary.opacity(0.15))
                            )
                            .foregroundStyle(selection == choice ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("DogfoodPaneChoice-\(item.id)-\(choice)")
                }
            }
        }
    }
}
#endif
