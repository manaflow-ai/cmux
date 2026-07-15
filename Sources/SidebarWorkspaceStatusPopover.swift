import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Shared status lane list

/// One selectable status lane row, shared by the sidebar row's context-menu
/// Status submenu and the todo pane's status popover so both surfaces present
/// identical lanes, titles, and selection through one model, and apply through
/// the same `WorkspaceTodoActions.applyStatusOverride` path. Sidebar workspace
/// rows deliberately draw no status glyph (the leading status circles were
/// removed; see `SidebarWorkspaceRowStatusGlyphRemovalTests`).
struct WorkspaceTodoStatusLane: Equatable, Identifiable {
    /// The lane to pin, or `nil` for Auto (clear the override) and for None.
    let status: WorkspaceTaskStatus?
    let title: String
    let isSelected: Bool
    /// The None row: opt the workspace out of the feature (hide the glyph).
    var isNone: Bool = false

    var id: String { isNone ? "none" : (status?.rawValue ?? "auto") }
}

extension WorkspaceTodoStatusLane {
    /// The ordered lane list: Auto first, then the five status lanes, then None.
    ///
    /// - Parameters:
    ///   - inferred: The lane the live signals currently infer.
    ///   - activeOverride: The pinned lane, or `nil` while automatic.
    ///   - isHidden: Whether the workspace is opted out (None active).
    static func lanes(
        inferred: WorkspaceTaskStatus,
        activeOverride: WorkspaceTaskStatus?,
        isHidden: Bool = false
    ) -> [WorkspaceTodoStatusLane] {
        var lanes = [WorkspaceTodoStatusLane(
            status: nil,
            title: autoTitle(inferred: inferred, hasOverride: activeOverride != nil),
            isSelected: activeOverride == nil && !isHidden
        )]
        lanes += WorkspaceTaskStatus.allCases.map { status in
            WorkspaceTodoStatusLane(
                status: status,
                title: status.displayName,
                isSelected: !isHidden && activeOverride == status
            )
        }
        lanes.append(WorkspaceTodoStatusLane(
            status: nil,
            title: String(localized: "sidebar.status.none", defaultValue: "None (hide status)"),
            isSelected: isHidden,
            isNone: true
        ))
        return lanes
    }

    /// "Auto — {inferred}" while automatic; "Auto — return to {inferred}"
    /// while a manual lane is pinned.
    static func autoTitle(inferred: WorkspaceTaskStatus, hasOverride: Bool) -> String {
        if hasOverride {
            return String(
                format: String(
                    localized: "sidebar.status.autoReturn",
                    defaultValue: "Auto — return to %@"
                ),
                locale: .current,
                inferred.displayName
            )
        }
        return String(
            format: String(
                localized: "contextMenu.workspaceStatus.auto",
                defaultValue: "Auto — %@"
            ),
            locale: .current,
            inferred.displayName
        )
    }
}

// MARK: - Popover model

/// The value snapshot the status popover renders (Equatable so the NSPopover
/// host only rebuilds content when it actually changes).
struct SidebarWorkspaceStatusPopoverModel: Equatable {
    /// The lane the live signals currently infer.
    let inferred: WorkspaceTaskStatus
    /// The pinned lane, or `nil` while automatic.
    let activeOverride: WorkspaceTaskStatus?
    /// Whether the workspace is opted out (None active).
    var isHidden: Bool = false
}

// MARK: - Popover content

/// The status popover opened from the todo pane's header glyph: the Auto row,
/// a divider, the five status lanes (each drawing the real glyph), and —
/// while a lane is pinned — a footnote explaining the pin auto-clears. Arrow
/// keys move the highlight, Return or click applies and closes, Esc closes,
/// and a lane's first letter jumps.
struct SidebarWorkspaceStatusPopover: View {
    let model: SidebarWorkspaceStatusPopoverModel
    /// Applies a lane (`nil` = Auto) through the shared status action path.
    let onSelectLane: @MainActor (WorkspaceTaskStatus?) -> Void
    /// Opts the workspace out (None): hide the status glyph.
    let onSelectNone: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @State private var highlightedIndex: Int
    @FocusState private var isFocused: Bool

    /// Draws the lane glyphs at ~12pt (the row glyph's base size is 9pt).
    private static let glyphFontScale: CGFloat = 12.0 / 9.0

    init(
        model: SidebarWorkspaceStatusPopoverModel,
        onSelectLane: @escaping @MainActor (WorkspaceTaskStatus?) -> Void,
        onSelectNone: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.onSelectLane = onSelectLane
        self.onSelectNone = onSelectNone
        self.onClose = onClose
        let lanes = WorkspaceTodoStatusLane.lanes(
            inferred: model.inferred,
            activeOverride: model.activeOverride,
            isHidden: model.isHidden
        )
        _highlightedIndex = State(initialValue: lanes.firstIndex(where: \.isSelected) ?? 0)
    }

    private var lanes: [WorkspaceTodoStatusLane] {
        WorkspaceTodoStatusLane.lanes(
            inferred: model.inferred,
            activeOverride: model.activeOverride,
            isHidden: model.isHidden
        )
    }

    var body: some View {
        let lanes = self.lanes
        VStack(alignment: .leading, spacing: 1) {
            laneRow(lanes[0], index: 0)
            Divider()
                .padding(.vertical, 3)
            ForEach(Array(lanes.dropFirst().enumerated()), id: \.element.id) { offset, lane in
                laneRow(lane, index: offset + 1)
            }
            if model.activeOverride != nil {
                Text(String(
                    localized: "sidebar.statusPopover.pinFootnote",
                    defaultValue: "Pinned status clears when activity changes"
                ))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
        .padding(6)
        .frame(width: 200, alignment: .leading)
        .background(PopoverKeyWindowElevator())
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .task { isFocused = true }
        .onKeyPress(.upArrow) {
            moveHighlight(-1, laneCount: lanes.count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveHighlight(1, laneCount: lanes.count)
            return .handled
        }
        .onKeyPress(.return) {
            applyHighlighted(lanes)
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onKeyPress { press in
            jumpToLane(startingWith: press.characters, lanes: lanes) ? .handled : .ignored
        }
        .onExitCommand { onClose() }
        .accessibilityIdentifier("SidebarWorkspaceStatusPopover")
    }

    private func laneRow(_ lane: WorkspaceTodoStatusLane, index: Int) -> some View {
        Button {
            apply(lane)
        } label: {
            HStack(spacing: 5) {
                if let status = lane.status {
                    SidebarWorkspaceTaskStatusGlyph(
                        status: status,
                        hasOverride: false,
                        usesMonochrome: false,
                        monochromeColor: .primary,
                        neutralColor: .secondary,
                        fontScale: Self.glyphFontScale
                    )
                } else {
                    Color.clear
                        .frame(width: 11 * Self.glyphFontScale, height: 1)
                }
                Text(lane.title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if lane.isSelected {
                    CmuxSystemSymbolImage(systemName: "checkmark", pointSize: 10, weight: .semibold)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(index == highlightedIndex ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlightedIndex = index }
        }
        .accessibilityIdentifier("SidebarWorkspaceStatusPopoverLane.\(lane.id)")
    }

    /// Applies a lane through the shared status path, then dismisses like a
    /// standard menu selection.
    private func apply(_ lane: WorkspaceTodoStatusLane) {
        if lane.isNone {
            onSelectNone()
        } else {
            onSelectLane(lane.status)
        }
        onClose()
    }

    private func applyHighlighted(_ lanes: [WorkspaceTodoStatusLane]) {
        guard lanes.indices.contains(highlightedIndex) else { return }
        apply(lanes[highlightedIndex])
    }

    private func moveHighlight(_ delta: Int, laneCount: Int) {
        guard laneCount > 0 else { return }
        highlightedIndex = (highlightedIndex + delta + laneCount) % laneCount
    }

    /// Jumps the highlight to the first lane whose title starts with the
    /// typed letter (case-insensitive). Returns whether a lane matched.
    private func jumpToLane(startingWith characters: String, lanes: [WorkspaceTodoStatusLane]) -> Bool {
        let typed = characters.lowercased()
        guard !typed.isEmpty, typed.rangeOfCharacter(from: .alphanumerics) != nil else { return false }
        guard let index = lanes.firstIndex(where: { $0.title.lowercased().hasPrefix(typed) }) else {
            return false
        }
        highlightedIndex = index
        return true
    }
}

