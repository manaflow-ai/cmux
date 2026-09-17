#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The workspace list's view-options card: Mail-style illustrated sort tiles
/// on top (each schematic renders what the mode actually does to the list, so
/// "Computer Order" needs no explanation), then the read-state and machine
/// filter rows.
///
/// A native `Menu` bridges to UIMenu, whose rows only render text plus an
/// icon-sized image, so graphics this size are impossible there; this is a
/// popover styled like a menu card instead. Selection does not dismiss: the
/// list re-sorts live behind the card, which is the whole payoff of the
/// illustrated tiles.
struct WorkspaceListViewOptionsPopover: View {
    let filter: MobileWorkspaceListFilter
    /// `nil` hides the sort tiles (single-machine scope keeps the Mac's order).
    let sortMode: MobileWorkspaceSortMode?
    /// Computers offered by the order editor, effective order first.
    var orderMachines: [WorkspaceFilterMachine] = []
    /// Persist a new computer order. `nil` hides the editor row.
    var saveComputerOrder: (([String]) -> Void)? = nil
    let actions: WorkspaceListFilterMenuActions

    /// The order editor presents from the popover itself: a parent-level sheet
    /// cannot present while this popover owns the presentation slot. It opens
    /// only from the explicit row below the tiles — selecting the Computer
    /// Order tile just selects; no surprise navigation.
    @State private var showingOrderEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let sortMode, let setSortMode = actions.setSortMode {
                    sortTiles(selected: sortMode) { picked in
                        setSortMode(picked)
                    }
                    if sortMode == .computerPriority, saveComputerOrder != nil {
                        Divider().padding(.horizontal, 14)
                        row(
                            title: L10n.string(
                                "mobile.workspaces.sort.editOrder",
                                defaultValue: "Edit Computer Order…"
                            ),
                            systemImage: "arrow.up.arrow.down",
                            checked: false
                        ) {
                            showingOrderEditor = true
                        }
                        .accessibilityIdentifier("MobileWorkspaceSortEditOrder")
                    }
                    sectionBreak
                }

                row(
                    title: L10n.string("mobile.workspaces.filter.all", defaultValue: "All Workspaces"),
                    checked: filter.readState == .all
                ) {
                    actions.setReadState(.all)
                }
                row(
                    title: L10n.string("mobile.workspaces.filter.unread", defaultValue: "Unread"),
                    checked: filter.readState == .unread
                ) {
                    actions.setReadState(.unread)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 300, maxWidth: 320)
        // The popover inherits the presenting toolbar button's font
        // environment; pin every row to regular body so nothing renders with
        // the toolbar's weight. Tile labels re-set their own smaller font.
        .font(.body)
        .fontWeight(.regular)
        .presentationCompactAdaptation(.popover)
        .sheet(isPresented: $showingOrderEditor) {
            if let saveComputerOrder {
                WorkspaceComputerOrderSheet(
                    machines: orderMachines,
                    save: saveComputerOrder
                )
            }
        }
    }

    private var sectionBreak: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.5))
            .frame(height: 6)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sortTiles(
        selected: MobileWorkspaceSortMode,
        select: @escaping (MobileWorkspaceSortMode) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(MobileWorkspaceSortMode.allCases, id: \.self) { mode in
                WorkspaceSortModeTile(
                    mode: mode,
                    isSelected: mode == selected,
                    select: { select(mode) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .accessibilityIdentifier("MobileWorkspaceSortPicker")
    }

    @ViewBuilder
    private func row(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        checked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.subheadline)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One illustrated sort-mode choice: a miniature workspace list drawn the way
/// this mode would render it, the localized label, and a Mail-style radio.
struct WorkspaceSortModeTile: View {
    let mode: MobileWorkspaceSortMode
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                WorkspaceSortModeSchematic(mode: mode)
                    .frame(width: 72, height: 96)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color(.separator),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                Text(mode.displayName)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileWorkspaceSortTile-\(mode.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(mode.displayName)
    }
}

/// The miniature list rendering for one sort mode. Two computers are drawn in
/// distinct tints; the shapes carry the meaning, no text:
/// - automatic: computer-headed sections, first computer's section leading.
/// - computerPriority: the same sections with rank badges and drag grips —
///   the order is yours.
/// - recentActivity: whole group sections ranked beside ungrouped rows by
///   activity, with clocks marking the time-based order.
struct WorkspaceSortModeSchematic: View {
    let mode: MobileWorkspaceSortMode

    private let firstTint = Color.blue
    private let secondTint = Color.orange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch mode {
            case .automatic:
                header(tint: firstTint, symbol: "laptopcomputer")
                rowBar; rowBar
                header(tint: secondTint, symbol: "desktopcomputer")
                rowBar
            case .computerPriority:
                header(tint: secondTint, symbol: "desktopcomputer", rank: 1, grip: true)
                rowBar
                header(tint: firstTint, symbol: "laptopcomputer", rank: 2, grip: true)
                rowBar; rowBar
            case .recentActivity:
                timedRow(tint: secondTint, width: 0.8)
                header(tint: firstTint, symbol: "folder.fill")
                timedRow(tint: firstTint, width: 0.9, indented: true)
                timedRow(tint: firstTint, width: 0.65, indented: true)
                header(tint: secondTint, symbol: "folder.fill")
                timedRow(tint: secondTint, width: 0.75, indented: true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func header(tint: Color, symbol: String, rank: Int? = nil, grip: Bool = false) -> some View {
        // Rank badges read as part of the miniature content, not the frame, so
        // they take an extra indent off the tile border.
        HStack(spacing: 3) {
            if let rank {
                Text("\(rank)")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 10, height: 10)
                    .background(Circle().fill(tint))
                    .padding(.leading, 4)
            }
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.55))
                .frame(width: 18, height: 5)
            Spacer(minLength: 0)
            if grip {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var rowBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(.tertiarySystemFill))
            .frame(height: 7)
            .padding(.leading, 8)
    }

    @ViewBuilder
    private func timedRow(tint: Color, width: CGFloat, indented: Bool = false) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(tint.opacity(0.8))
                .frame(width: 5, height: 5)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(.tertiarySystemFill))
                .frame(height: 7)
                .frame(maxWidth: .infinity)
                .scaleEffect(x: width, y: 1, anchor: .leading)
            Image(systemName: "clock")
                .font(.system(size: 6))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, indented ? 8 : 0)
    }
}
#endif
