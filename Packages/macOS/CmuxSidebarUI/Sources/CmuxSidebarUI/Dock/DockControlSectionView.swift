public import CmuxSidebar
public import CoreGraphics
public import SwiftUI

/// One control's header-plus-terminal row in the project Dock.
///
/// A pure presentation leaf generic over the terminal subtree it hosts: it
/// renders the numbered header (ordinal, title, command, focus and restart
/// buttons) above a fixed-height, clipped `terminalContent` region. The control
/// data arrives as an immutable ``DockControlSnapshot`` and the focus/restart
/// actions arrive as closures, so this view never reaches into live control
/// runtime state. The focus and restart button copy is resolved (and localized)
/// app-side and passed in, so the package view binds to no bundle.
public struct DockControlSectionView<TerminalContent: View>: View {
    let snapshot: DockControlSnapshot
    let ordinal: Int
    let terminalHeight: CGFloat
    let focusControlLabel: String
    let restartControlLabel: String
    let onFocus: () -> Void
    let onRestart: () -> Void
    @ViewBuilder let terminalContent: () -> TerminalContent

    /// Creates a Dock control section row.
    /// - Parameters:
    ///   - snapshot: Immutable presentation values for the control.
    ///   - ordinal: 1-based position shown in the header badge.
    ///   - terminalHeight: Fixed height the hosted terminal region is clipped to.
    ///   - focusControlLabel: Resolved (already localized) help/accessibility
    ///     label for the focus button.
    ///   - restartControlLabel: Resolved (already localized) help/accessibility
    ///     label for the restart button.
    ///   - onFocus: Invoked when the focus button is tapped.
    ///   - onRestart: Invoked when the restart button is tapped.
    ///   - terminalContent: The terminal subtree hosted beneath the header.
    public init(
        snapshot: DockControlSnapshot,
        ordinal: Int,
        terminalHeight: CGFloat,
        focusControlLabel: String,
        restartControlLabel: String,
        onFocus: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        @ViewBuilder terminalContent: @escaping () -> TerminalContent
    ) {
        self.snapshot = snapshot
        self.ordinal = ordinal
        self.terminalHeight = terminalHeight
        self.focusControlLabel = focusControlLabel
        self.restartControlLabel = restartControlLabel
        self.onFocus = onFocus
        self.onRestart = onRestart
        self.terminalContent = terminalContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            terminalContent()
                .frame(height: terminalHeight)
                .clipped()
        }
        .accessibilityIdentifier("DockControl.\(snapshot.id)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(ordinal)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            Text(snapshot.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(snapshot.command)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                onFocus()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(focusControlLabel)
            .accessibilityLabel(focusControlLabel)

            Button {
                onRestart()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(restartControlLabel)
            .accessibilityLabel(restartControlLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: 30)
        .background(Color.primary.opacity(0.035))
    }
}
