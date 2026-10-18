import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel
import SwiftUI

struct CloudTreePlaceholderContent: View {
    let placeholder: CloudTreePlaceholder
    let style: CloudTreeStyle

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        HStack(alignment: .center, spacing: GlobalFontMagnification.scaledSize(style.iconGap, percent: magnification)) {
            Group {
                switch placeholder.style {
                case .connecting:
                    ProgressView().controlSize(.mini)
                case .error:
                    CmuxSystemSymbolImage(
                        systemName: "exclamationmark.triangle",
                        pointSize: max(style.iconSize, 9),
                        weight: .regular,
                        tint: Color(nsColor: .secondaryLabelColor)
                    )
                case .createMachine:
                    CmuxSystemSymbolImage(
                        systemName: "plus",
                        pointSize: max(style.iconSize, 9),
                        weight: .medium,
                        tint: Color(nsColor: .secondaryLabelColor)
                    )
                case .empty:
                    // Keeps the icon column so the text lines up with the
                    // rows it stands in for, like "No other devices yet".
                    Color.clear
                case .dimmed:
                    CmuxSystemSymbolImage(
                        systemName: "moon.zzz",
                        pointSize: max(style.iconSize, 9),
                        weight: .regular,
                        tint: Color(nsColor: .tertiaryLabelColor)
                    )
                }
            }
            .frame(width: max(style.iconSlot, 12))
            Text(placeholder.text)
                .cmuxFont(size: placeholder.style == .empty ? style.detailSize : style.detailSize + 1, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            if let action = placeholder.action {
                // The next step, in the accent color: the whole row is its
                // button (the outline's click runs `CloudTreePlaceholder.Action`).
                Text(Self.actionTitle(action))
                    .cmuxFont(size: style.detailSize + 1, weight: .medium, design: style.fontDesign)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, style.rowGrid.trailingPadding)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(placeholder.action == nil ? [] : .isButton)
    }

    static func actionTitle(_ action: CloudTreePlaceholder.Action) -> String {
        switch action {
        case .newTerminal:
            return String(localized: "cloudTree.placeholder.action.newTerminal", defaultValue: "New Terminal")
        case .newWorkspace:
            return String(localized: "cloudTree.placeholder.action.newWorkspace", defaultValue: "New Workspace")
        }
    }
}

/// Runs an empty category's next step through the same tree actions as the
/// category's hover "+" and context menu, so all three create identically.
enum CloudTreePlaceholderActionDispatch {
    @MainActor
    static func perform(_ action: CloudTreePlaceholder.Action, machine: SurfaceMachineID, actions: CloudTreeNodeActions) {
        switch action {
        case .newTerminal:
            actions.newTerminal(machine, nil)
        case .newWorkspace:
            actions.newWorkspace(machine)
        }
    }
}
