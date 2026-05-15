import Observation
import SwiftUI

enum CommandPaletteRenderTrailingLabelStyle: Equatable {
    case shortcut
    case kind
}

struct CommandPaletteRenderTrailingLabel: Equatable {
    let text: String
    let style: CommandPaletteRenderTrailingLabelStyle
}

struct CommandPaletteRenderResultRow: Identifiable, Equatable {
    let id: String
    let title: String
    let matchedIndices: Set<Int>
    let trailingLabel: CommandPaletteRenderTrailingLabel?
}

struct CommandPaletteCommandListRenderState: Equatable {
    var resultsVersion: UInt64 = 0
    var emptyStateText: String = ""
    var listIdentity: String = "switcher"
    var rows: [CommandPaletteRenderResultRow] = []
    var selectedIndex: Int = 0
    var shouldShowEmptyState = false
    var scrollTargetID: String?
    var scrollTargetAnchor: UnitPoint?

    static let empty = CommandPaletteCommandListRenderState()
}

@MainActor
@Observable
final class CommandPaletteOverlayRenderModel {
    private(set) var commandList = CommandPaletteCommandListRenderState.empty
    @ObservationIgnored private var scheduledCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListResultsVersion: UInt64 = 0

    deinit {}

    func scheduleCommandListUpdate(_ state: CommandPaletteCommandListRenderState) {
        scheduledCommandListSequence &+= 1
        let sequence = scheduledCommandListSequence

        Task { @MainActor in
            await Task.yield()
            guard sequence >= appliedCommandListSequence else { return }
            guard state.resultsVersion >= appliedCommandListResultsVersion else { return }
            appliedCommandListSequence = sequence
            appliedCommandListResultsVersion = max(appliedCommandListResultsVersion, state.resultsVersion)
            updateCommandList(state)
        }
    }

    private func updateCommandList(_ state: CommandPaletteCommandListRenderState) {
        guard commandList != state else { return }
        commandList = state
    }
}

struct CommandPaletteCommandListRenderView: View {
    let renderModel: CommandPaletteOverlayRenderModel
    let onRunResult: (String) -> Void

    var body: some View {
        CommandPaletteCommandListRowsView(
            state: renderModel.commandList,
            onRunResult: onRunResult
        )
    }
}

struct CommandPaletteCommandListRowsView: View {
    let state: CommandPaletteCommandListRenderState
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
                            .font(.system(size: 13, weight: .regular))
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
                            ? cmuxAccentColor().opacity(0.12)
                            : (isHovered ? Color.primary.opacity(0.08) : .clear)

                        Button {
                            onRunResult(row.id)
                        } label: {
                            ContentView.commandPaletteRenderResultLabelContent(
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
