import SwiftUI

/// A quiet, always-visible create row. The outline owns selection and Return
/// handling; rendering the verb as a normal child row keeps the affordance
/// discoverable without adding a second button column to every workspace.
struct CloudTreeCreateRowContent: View {
    let kind: CloudTreeNode.Kind
    let style: CloudTreeStyle

    private var action: CloudTreeCreateAction? { CloudTreeCreateAction(row: kind) }

    var body: some View {
        HStack(alignment: .center, spacing: style.iconGap) {
            Image(systemName: "plus")
                .font(.system(size: style.iconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: style.iconSlot, alignment: .center)
            Text(action?.rowTitle ?? String(localized: "cloudTree.row.newTerminal", defaultValue: "New Terminal"))
                .cmuxFont(size: style.titleSize, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
        .help(destinationLabel)
        .accessibilityLabel(destinationLabel)
    }

    private var destinationLabel: String { action?.title ?? "" }

    /// Shared by the SwiftUI content and its native pass-through cell.
    static func destinationLabel(for kind: CloudTreeNode.Kind) -> String? {
        CloudTreeCreateAction(row: kind)?.title
    }
}
