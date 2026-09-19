import SwiftUI

/// A quiet, always-visible create row. The outline owns selection and Return
/// handling; rendering the verb as a normal child row keeps the affordance
/// discoverable without adding a second button column to every workspace.
struct CloudTreeCreateRowContent: View {
    let kind: CloudTreeNode.Kind
    let style: CloudTreeStyle

    var body: some View {
        HStack(alignment: .center, spacing: style.iconGap) {
            Image(systemName: "plus")
                .font(.system(size: style.iconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: style.iconSlot, alignment: .center)
            Text(title)
                .cmuxFont(size: style.titleSize, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
        .help(Self.destinationLabel(for: kind) ?? title)
        .accessibilityLabel(Self.destinationLabel(for: kind) ?? title)
    }

    private var title: String {
        switch kind {
        case .createWorkspace:
            return String(localized: "cloudTree.row.newWorkspace", defaultValue: "New Workspace")
        case .createTerminal:
            return String(localized: "cloudTree.row.newTerminal", defaultValue: "New Terminal")
        default:
            return ""
        }
    }

    /// Shared by the SwiftUI content and its native pass-through cell.
    static func destinationLabel(for kind: CloudTreeNode.Kind) -> String? {
        switch kind {
        case .createWorkspace(_, let machineName):
            return String(
                format: String(localized: "cloudTree.row.newWorkspace.help", defaultValue: "New Workspace on %@"),
                machineName
            )
        case .createTerminal(_, _, let workspaceName):
            return String(
                format: String(localized: "cloudTree.row.newTerminal.help", defaultValue: "New Terminal in %@"),
                workspaceName
            )
        default:
            return nil
        }
    }
}
