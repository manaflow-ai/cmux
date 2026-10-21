import SwiftUI

/// One change in the change list, with its Undo button. Value snapshot and
/// an action only (no store below the list boundary).
struct ChiefMemoryChangeRow: View {
    let change: ChiefMemoryChange
    let undo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: change.op == "delete" ? ChiefMemoryStrings.deleted : ChiefMemoryStrings.edited,
                            change.target.label))
                    .font(.callout)
                Text(change.old).font(.caption).foregroundStyle(.secondary).lineLimit(1).strikethrough()
                if change.op != "delete" {
                    Text(change.new).font(.caption).lineLimit(1)
                }
            }
            Spacer()
            if change.undone {
                Text(ChiefMemoryStrings.undone).font(.caption).foregroundStyle(.secondary)
            } else {
                Button(ChiefMemoryStrings.undo, action: undo)
            }
        }
        .padding(.vertical, 3)
    }
}
