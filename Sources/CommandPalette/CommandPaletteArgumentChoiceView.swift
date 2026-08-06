import CmuxCommandPalette
import SwiftUI

/// Palette step that presents one finite-choice command argument.
struct CommandPaletteArgumentChoiceView: View {
    let commandTitle: String
    let instruction: String
    let commandID: String
    let argument: CommandPaletteChoiceArgument
    let selectedIndex: Int
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(commandTitle)
                    .cmuxFont(size: 13, weight: .medium)
                    .lineLimit(1)
                Text(instruction)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            CommandPaletteCommandListRowsView(
                state: renderState,
                onRunResult: onSelect
            )
        }
    }

    private var renderState: CommandPaletteCommandListRenderState {
        let resolvedIndex = argument.choices.isEmpty
            ? 0
            : min(max(selectedIndex, 0), argument.choices.count - 1)
        let rows = argument.choices.map { choice in
            CommandPaletteRenderResultRow(
                id: choice.value,
                title: choice.title,
                matchedIndices: [],
                trailingLabel: nil
            )
        }
        return CommandPaletteCommandListRenderState(
            resultsVersion: 0,
            emptyStateText: "",
            listIdentity: "arguments.\(commandID).\(argument.name)",
            rows: rows,
            selectedIndex: resolvedIndex,
            shouldShowEmptyState: false,
            scrollTargetID: rows.indices.contains(resolvedIndex) ? rows[resolvedIndex].id : nil,
            scrollTargetAnchor: ContentView.commandPaletteScrollPositionAnchor(
                selectedIndex: resolvedIndex,
                resultCount: rows.count
            )
        )
    }
}
