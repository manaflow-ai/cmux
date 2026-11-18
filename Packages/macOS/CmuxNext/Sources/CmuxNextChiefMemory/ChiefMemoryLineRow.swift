import CmuxNextDesign
import CmuxVisibleRows
import SwiftUI

/// One line in the view or search list: its node name, level and text.
/// Value snapshot and an action only (no store below the list boundary).
struct ChiefMemoryLineRow: View, Equatable {
    let name: String
    let detail: String
    let text: String
    let stale: Bool
    let selected: Bool
    let open: () -> Void
    /// The inspector's work meter (``ChiefMemoryInspectorModel/listWork``): each body counts one row configured.
    let work: ListWorkMeter

    /// Equal when what the row draws is: the inspector makes `open` again with each body.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.detail == rhs.detail && lhs.text == rhs.text && lhs.stale == rhs.stale
            && lhs.selected == rhs.selected
    }

    var body: some View {
        work.configured()
        return Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                    if stale {
                        Text(ChiefMemoryStrings.stale)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                }
                Text(text).font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).fill(selected ? Color(nsColor: Palette.selectionFill) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.cmuxPressFill)
    }
}
