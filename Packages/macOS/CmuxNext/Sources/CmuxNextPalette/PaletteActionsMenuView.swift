import CmuxNextDesign
import SwiftUI

/// The Cmd-K menu: every command of the selected item, filterable by typing.
struct PaletteActionsMenuView: View {
    let model: PaletteModel
    let menu: PaletteActionsMenuState

    var body: some View {
        let visible = menu.visibleCommands
        let alternateID = model.selectedItem?.alternate?.id
        VStack(alignment: .leading, spacing: 0) {
            Text(menu.itemTitle)
                .font(.token(Typography.header))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Metrics.space5)
                .padding(.top, Metrics.space4)
                .padding(.bottom, Metrics.space2)
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, command in
                    row(command, index: index, isAlternate: command.id == alternateID)
                }
            }
            .padding(.horizontal, Metrics.space2)
            Rectangle()
                .fill(Color.token(Palette.separator))
                .frame(height: Metrics.dividerThickness)
                .padding(.top, Metrics.space2)
            HStack(spacing: Metrics.space3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Metrics.smallIconSize))
                    .foregroundStyle(.tertiary)
                Text(menu.filter.isEmpty ? PaletteStrings.searchActionsPlaceholder : menu.filter)
                    .font(.token(Typography.body))
                    .foregroundStyle(menu.filter.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, Metrics.space5)
            .frame(height: PaletteLayout.actionsMenuRowHeight)
        }
        .frame(width: PaletteLayout.actionsMenuWidth)
        .glassEffect(.regular.tint(.token(Palette.glassTint)), in: .rect(cornerRadius: PaletteLayout.cornerRadius))
        .shadow(color: .black.opacity(0.16), radius: Metrics.space6, y: Metrics.space3)
    }

    private func row(_ command: PaletteCommand, index: Int, isAlternate: Bool) -> some View {
        HStack(spacing: Metrics.space4) {
            Image(systemName: command.symbol ?? "circle")
                .font(.system(size: Metrics.smallIconSize, weight: .medium))
                .frame(width: Metrics.iconSize + Metrics.space2)
                .foregroundStyle(.secondary)
            Text(command.title)
                .font(.token(Typography.body))
                .foregroundStyle(command.isDestructive ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: Metrics.space4)
            if index == 0 {
                KeycapsView(keycaps: ["↩"])
            } else if isAlternate {
                KeycapsView(keycaps: ["⌘", "↩"])
            }
        }
        .padding(.horizontal, Metrics.space4)
        .frame(height: PaletteLayout.actionsMenuRowHeight)
        .background {
            RoundedRectangle(cornerRadius: PaletteLayout.rowCornerRadius, style: .continuous)
                .fill(index == menu.selectedIndex ? Color.token(Palette.selectionFill) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.runActionsMenuCommand(at: index) }
    }
}
