import CmuxFoundation
public import SwiftUI
public import CmuxCommandPalette

/// Renders the materialized command-palette result rows from the coordinator's
/// command-list render state.
///
/// Lifted out of `ContentView` so the palette's result-list rendering lives in
/// the command-palette UI package. The selected-row accent tint is injected as a
/// color so the app's appearance token stays app-side; everything else renders
/// from the package render-state value types.
public struct CommandPaletteCommandListRenderView: View {
    private let coordinator: CommandPaletteCoordinator
    private let selectedRowBackground: Color
    private let onRunResult: (String) -> Void

    /// Creates the render view.
    /// - Parameters:
    ///   - coordinator: The palette coordinator owning the `commandList` render state.
    ///   - selectedRowBackground: Background tint for the selected row (app accent).
    ///   - onRunResult: Runs the result with the given command id.
    public init(
        coordinator: CommandPaletteCoordinator,
        selectedRowBackground: Color,
        onRunResult: @escaping (String) -> Void
    ) {
        self.coordinator = coordinator
        self.selectedRowBackground = selectedRowBackground
        self.onRunResult = onRunResult
    }

    public var body: some View {
        CommandPaletteCommandListRowsView(
            state: coordinator.commandList,
            selectedRowBackground: selectedRowBackground,
            onRunResult: onRunResult
        )
    }
}

/// The scrolling list of command-palette result rows.
struct CommandPaletteCommandListRowsView: View {
    let state: CommandPaletteCommandListRenderState
    let selectedRowBackground: Color
    let onRunResult: (String) -> Void
    @State private var hoveredIndex: Int?

    private static let listMaxHeight: CGFloat = 450
    private static let rowHeight: CGFloat = 24
    private static let emptyStateHeight: CGFloat = 44

    var body: some View {
        let contentHeight = state.rows.isEmpty
            ? Self.emptyStateHeight
            : CGFloat(state.rows.count) * Self.rowHeight
        let listHeight = min(Self.listMaxHeight, contentHeight)

        ScrollView {
            LazyVStack(spacing: 0) {
                if state.rows.isEmpty {
                    if state.shouldShowEmptyState {
                        Text(state.emptyStateText)
                            .cmuxFont(size: 13, weight: .regular)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.emptyStateHeight)
                    }
                } else {
                    ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                        let isSelected = index == state.selectedIndex
                        let isHovered = hoveredIndex == index
                        let rowBackground: Color = isSelected
                            ? selectedRowBackground
                            : (isHovered ? Color.primary.opacity(0.08) : .clear)

                        Button {
                            onRunResult(row.id)
                        } label: {
                            CommandPaletteResultLabel(
                                title: row.title,
                                matchedIndices: row.matchedIndices,
                                trailingLabel: row.trailingLabel
                            )
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowBackground)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("CommandPaletteResultRow.\(index)")
                        .accessibilityValue(row.id)
                        .onHover { hovering in
                            if hovering {
                                hoveredIndex = index
                            } else if hoveredIndex == index {
                                hoveredIndex = nil
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .id(state.listIdentity)
        .frame(height: listHeight)
        .scrollPosition(
            id: Binding(
                get: { state.scrollTargetID },
                // Ignore passive readback so manual scrolling doesn't mutate selection-follow state.
                set: { _ in }
            ),
            anchor: state.scrollTargetAnchor
        )
        .onChange(of: state.rows.count) { _, count in
            if let hoveredIndex, hoveredIndex >= count {
                self.hoveredIndex = nil
            }
        }
    }
}

/// A single result row's label: the fuzzy-highlighted title plus an optional
/// trailing shortcut/kind label.
struct CommandPaletteResultLabel: View {
    let title: String
    let matchedIndices: Set<Int>
    let trailingLabel: CommandPaletteRenderTrailingLabel?

    var body: some View {
        HStack(spacing: 8) {
            Self.highlightedTitleText(title, matchedIndices: matchedIndices)
                .cmuxFont(size: 13, weight: .regular)
                .lineLimit(1)
            Spacer()
            trailingLabelView
        }
    }

    private static func highlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
        guard !matchedIndices.isEmpty else {
            return Text(title).foregroundColor(.primary)
        }

        let chars = Array(title)
        var index = 0
        var result = Text("")

        while index < chars.count {
            let isMatched = matchedIndices.contains(index)
            var end = index + 1
            while end < chars.count, matchedIndices.contains(end) == isMatched {
                end += 1
            }

            let segment = String(chars[index..<end])
            if isMatched {
                result = result + Text(segment).foregroundColor(.blue)
            } else {
                result = result + Text(segment).foregroundColor(.primary)
            }
            index = end
        }

        return result
    }

    @ViewBuilder
    private var trailingLabelView: some View {
        if let trailingLabel {
            switch trailingLabel.style {
            case .shortcut:
                Text(trailingLabel.text)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            case .kind:
                Text(trailingLabel.text)
                    .cmuxFont(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
